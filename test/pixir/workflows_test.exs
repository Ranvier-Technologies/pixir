defmodule Pixir.WorkflowsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Log, Session, SessionSupervisor, Subagents, Workflows}
  alias Pixir.Permissions.WritePolicy

  defmodule EchoProvider do
    def stream(%{history: history} = request, opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      if pid = Keyword.get(opts, :test_pid) do
        send(pid, {:workflow_prompt, prompt})
        send(pid, {:workflow_request, request})

        send(
          pid,
          {:workflow_knobs, request[:model] || Keyword.get(opts, :model),
           request[:reasoning_effort] || Keyword.get(opts, :reasoning_effort)}
        )
      end

      step =
        prompt
        |> String.split("\n")
        |> Enum.find_value("unknown", fn
          "Step: " <> id -> id
          _ -> nil
        end)

      {:ok,
       %{
         text: "summary:#{step}",
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  defmodule PartialProvider do
    def stream(%{history: history}, _opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      step =
        prompt
        |> String.split("\n")
        |> Enum.find_value("unknown", fn
          "Step: " <> id -> id
          _ -> nil
        end)

      case step do
        "fail" ->
          {:error, Pixir.Tool.error(:command_failed, "planned failure", %{step: step})}

        "partial" ->
          {:ok,
           %{
             text: "checkpoint_status: partial\npartial evidence from #{step}",
             reasoning: "",
             reasoning_items: [],
             function_calls: [],
             finish_reason: :stop
           }}

        _ ->
          {:ok,
           %{
             text: "summary:#{step}",
             reasoning: "",
             reasoning_items: [],
             function_calls: [],
             finish_reason: :stop
           }}
      end
    end
  end

  defmodule BlockingProvider do
    def stream(_request, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:blocking_provider_started, self()})
      Process.sleep(10_000)

      {:ok,
       %{
         text: "late",
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  # Issues one write outside the allowlist, then finishes. The denial is
  # recoverable (#446), so the step still reaches checkpoint_ready while the
  # checkpoint payload confesses it.
  defmodule DeniedWriteProvider do
    def stream(%{history: history}, _opts) do
      denied? =
        Enum.any?(history, fn
          %{type: :tool_call, data: %{"call_id" => "denied-write"}} -> true
          _event -> false
        end)

      if denied? do
        {:ok,
         %{
           text: "summary:probed the boundary and stopped",
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
               call_id: "denied-write",
               name: "write",
               args: %{"path" => "outside.txt", "content" => "nope"}
             }
           ],
           finish_reason: :tool_calls
         }}
      end
    end
  end

  # Completes every child and self-declares the checkpoint_status named by the
  # step id prefix (`partial_*`, `failed_*`, `needs_orchestrator_*`); anything
  # else completes without a marker and therefore defaults to checkpoint_ready.
  defmodule MarkerProvider do
    def stream(%{history: history}, opts) do
      prompt =
        history
        |> Enum.find(&(&1.type == :user_message))
        |> then(&((&1 && &1.data["text"]) || ""))

      step =
        prompt
        |> String.split("\n")
        |> Enum.find_value("unknown", fn
          "Step: " <> id -> id
          _ -> nil
        end)

      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:marker_prompt, step, prompt})

      text =
        cond do
          String.starts_with?(step, "partial") ->
            "checkpoint_status: partial\nwrote the files"

          String.starts_with?(step, "failed") ->
            "checkpoint_status: failed\ngave up"

          String.starts_with?(step, "needs_orchestrator") ->
            "checkpoint_status: needs_orchestrator"

          true ->
            "summary:#{step}"
        end

      {:ok,
       %{
         text: text,
         reasoning: "",
         reasoning_items: [],
         function_calls: [],
         finish_reason: :stop
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-workflows-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "source.txt"), "workflow source")
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid}
  end

  defp workflow_policy(paths) do
    WritePolicy.normalize(%{
      "version" => 1,
      "metadata" => %{"id" => "workflow-test"},
      "allow_writes" => paths
    })
  end

  defp apply_workflow(path) do
    %{
      "steps" => [
        %{
          "id" => "propose",
          "task" => "propose edit",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => ["true"]
        },
        %{
          "id" => "apply",
          "apply_from" => "propose",
          "depends_on" => ["propose"],
          "write_set" => [path]
        }
      ]
    }
  end

  defp add_artifact(path, content) do
    %{
      "kind" => "virtual_diff",
      "version" => 1,
      "changes" => [
        %{
          "path" => path,
          "operation" => "add",
          "after" => %{"content" => content, "sha256" => sha256(content)},
          "diff" => %{"truncated" => false}
        }
      ]
    }
  end

  defp modify_artifact(path, before, after_content) do
    %{
      "kind" => "virtual_diff",
      "version" => 1,
      "changes" => [
        %{
          "path" => path,
          "operation" => "modify",
          "before" => %{"sha256" => sha256(before)},
          "after" => %{"content" => after_content, "sha256" => sha256(after_content)},
          "diff" => %{"truncated" => false}
        }
      ]
    }
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  test "documents the Workflow result and checkpoint status contract" do
    assert Workflows.workflow_statuses() == ~w(completed partial)

    assert Workflows.checkpoint_statuses() ==
             ~w(checkpoint_ready partial failed held needs_orchestrator)

    assert List.last(Workflows.proof_states()) == "completion_ready"
    assert List.last(Workflows.partial_proof_states()) == "partial_outcome_ready"

    assert Workflows.proof_states() -- Workflows.partial_proof_states() == [
             "dry_run_planned",
             "completion_ready"
           ]
  end

  test "dry_run creates structural waves and serializes write-set conflicts", %{ws: ws} do
    assert {:ok, plan} = Workflows.dry_run(conflict_workflow(), workspace: ws)

    assert plan["proof_states"] == Workflows.dry_run_proof_states()
    assert Enum.any?(plan["waves"], &("inspect_a" in &1 and "inspect_b" in &1))
    refute Enum.any?(plan["waves"], &("write_a" in &1 and "write_b" in &1))
    assert List.last(plan["waves"]) == ["summarize"]

    writer_plans = Enum.filter(plan["would_run"], &(&1["posture"] == "writer"))
    assert Enum.all?(writer_plans, &(&1["write_set"] == ["shared/result.txt"]))
  end

  test "dry_run serializes apply against overlapping readers", %{ws: ws} do
    {:ok, policy} = workflow_policy(["shared.txt"])

    spec = %{
      "steps" => [
        %{
          "id" => "propose",
          "task" => "p",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => ["true"]
        },
        %{
          "id" => "apply",
          "apply_from" => "propose",
          "depends_on" => ["propose"],
          "write_set" => ["shared.txt"]
        },
        %{
          "id" => "reader",
          "task" => "read the applied file",
          "agent" => "explorer",
          "permission_mode" => "read_only",
          "read_set" => ["shared.txt"],
          "depends_on" => ["propose"]
        }
      ]
    }

    assert {:ok, plan} = Workflows.dry_run(spec, workspace: ws, write_policy: policy)

    # apply mutates the parent workspace directly: a reader with an
    # overlapping read_set never shares its wave, in either wave order.
    refute Enum.any?(plan["waves"], &("apply" in &1 and "reader" in &1))
    assert Enum.any?(plan["waves"], &("apply" in &1))
    assert Enum.any?(plan["waves"], &("reader" in &1))
  end

  test "dry_run respects max_concurrency", %{ws: ws} do
    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "max_concurrency" => 2,
                 "steps" => [
                   %{"id" => "a", "task" => "A", "agent" => "explorer"},
                   %{"id" => "b", "task" => "B", "agent" => "explorer"},
                   %{"id" => "c", "task" => "C", "agent" => "explorer"}
                 ]
               },
               workspace: ws
             )

    assert Enum.map(plan["waves"], &length/1) == [2, 1]
  end

  test "empty writer write sets normalize to whole-workspace", %{ws: ws} do
    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "writer", "task" => "write", "agent" => "worker", "write_set" => []}
                 ]
               },
               workspace: ws
             )

    assert [%{"write_set" => ["**/*"]}] = plan["would_run"]
  end

  test "bounded write policy requires explicit writer write_set", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "workflow-test"},
        "allow_writes" => ["shared/**"]
      })

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "writer", "task" => "write", "agent" => "worker"}
                 ]
               },
               workspace: ws,
               write_policy: policy
             )

    assert details["field"] == "write_set"
  end

  test "bounded write policy narrows writer child policy to write_set", %{ws: ws} do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "workflow-test"},
        "allow_writes" => ["shared/**"]
      })

    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{
                     "id" => "writer",
                     "task" => "write",
                     "agent" => "worker",
                     "write_set" => ["shared/result.txt"]
                   }
                 ]
               },
               workspace: ws,
               write_policy: policy
             )

    assert [%{"write_policy" => write_policy}] = plan["would_run"]
    assert write_policy["allow_writes"] == ["shared/result.txt"]
    assert write_policy["id"] == "workflow-test"
  end

  test "dry_run expands skill-backed workflow templates into ordinary workflow plans", %{
    ws: ws
  } do
    skill_dir = write_skill(Path.join(ws, ".agents/skills/planner"), "planner", "Planner skill")

    write_workflow_template(skill_dir, "readonly_review", %{
      "id" => "readonly_review",
      "parameters" => %{"topic" => %{"type" => "string", "required" => true}},
      "workflow" => %{
        "id" => "review_{{topic}}",
        "max_concurrency" => 2,
        "steps" => [
          %{"id" => "inspect_a", "task" => "Inspect {{topic}}", "agent" => "explorer"},
          %{"id" => "inspect_b", "task" => "Inspect {{topic}} again", "agent" => "explorer"},
          %{
            "id" => "synthesize",
            "task" => "Synthesize {{topic}}",
            "agent" => "explorer",
            "depends_on" => ["inspect_a", "inspect_b"]
          }
        ]
      }
    })

    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "template_id" => "planner/readonly_review",
                 "template_args" => %{"topic" => "repository"}
               },
               workspace: ws
             )

    assert plan["template"]["template_id"] == "planner/readonly_review"
    assert plan["workflow_id"] == "review_repository"
    assert Enum.map(plan["would_run"], & &1["id"]) == ["inspect_a", "inspect_b", "synthesize"]
    assert hd(plan["would_run"])["read_set"] == ["**/*"]
  end

  test "dry_run plans explicit virtual_overlay steps", %{ws: ws} do
    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{
                     "id" => "scratch",
                     "task" => "scratch edit",
                     "workspace_mode" => "virtual_overlay",
                     "read_set" => ["source.txt"],
                     "virtual_commands" => ["sed -i 's/workflow/virtual/' source.txt"]
                   }
                 ]
               },
               workspace: ws
             )

    assert [
             %{
               "id" => "scratch",
               "workspace_mode" => "virtual_overlay",
               "posture" => "virtual_scratch",
               "read_set" => ["source.txt"],
               "write_set" => [],
               "virtual_commands" => ["sed -i 's/workflow/virtual/' source.txt"]
             }
           ] = plan["would_run"]
  end

  test "dry_run plans apply_from steps without artifact content", %{ws: ws} do
    {:ok, policy} = workflow_policy(["applied.txt"])

    assert {:ok, plan} =
             Workflows.dry_run(apply_workflow("applied.txt"), workspace: ws, write_policy: policy)

    assert [_producer, apply] = plan["would_run"]
    assert apply["id"] == "apply"
    assert apply["posture"] == "apply"
    assert apply["apply_from"] == "propose"
    assert apply["write_set"] == ["applied.txt"]
    refute Map.has_key?(apply, "virtual_diff")
    refute Map.has_key?(apply, "virtual_diff_apply")
  end

  test "apply_from validation rejects in dry_run and run", %{sid: sid, ws: ws} do
    {:ok, policy} = workflow_policy(["applied.txt"])

    specs = [
      %{
        "steps" => [
          %{
            "id" => "apply",
            "apply_from" => "missing",
            "depends_on" => ["missing"],
            "write_set" => ["applied.txt"]
          }
        ]
      },
      %{
        "steps" => [
          # read_only so the general writer-needs-write_set rule does not fire
          # first: this case pins the apply_from-must-be-virtual rejection.
          %{"id" => "plain", "task" => "plain", "permission_mode" => "read_only"},
          %{
            "id" => "apply",
            "apply_from" => "plain",
            "depends_on" => ["plain"],
            "write_set" => ["applied.txt"]
          }
        ]
      },
      %{
        "steps" => [
          %{
            "id" => "propose",
            "task" => "p",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["source.txt"],
            "virtual_commands" => ["true"]
          },
          %{"id" => "apply", "apply_from" => "propose", "write_set" => ["applied.txt"]}
        ]
      },
      %{
        "steps" => [
          %{
            "id" => "propose",
            "task" => "p",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["source.txt"],
            "virtual_commands" => ["true"]
          },
          %{"id" => "apply", "apply_from" => "propose", "depends_on" => ["propose"]}
        ]
      },
      %{
        "steps" => [
          %{
            "id" => "propose",
            "task" => "p",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["source.txt"],
            "virtual_commands" => ["true"]
          },
          %{
            "id" => "apply",
            "apply_from" => "propose",
            "depends_on" => ["propose"],
            "write_set" => ["applied.txt"],
            "agent" => "worker"
          }
        ]
      }
    ]

    # Each negative spec must fail for ITS OWN structured reason: expected
    # {location, next_actions} per case, in order. Locations are zero-based
    # JSON pointers into the spec.
    expectations = [
      {"/steps/0/apply_from", ["declare_the_virtual_overlay_producer_before_the_apply_step"]},
      {"/steps/1/apply_from", ["point_apply_from_at_a_virtual_overlay_step"]},
      {"/steps/1/apply_from", ["add_the_producer_to_depends_on"]},
      {"/steps/1/apply_from", ["add_explicit_write_set"]},
      {"/steps/1/apply_from", ["remove_apply_step_subagent_fields"]}
    ]

    for {spec, {location, next_actions}} <- Enum.zip(specs, expectations) do
      assert {:error, %{error: %{kind: :invalid_spec, details: details}}} =
               Workflows.dry_run(spec, workspace: ws, write_policy: policy)

      assert details["location"] == location
      assert details["next_actions"] == next_actions

      assert {:error, %{error: %{kind: :invalid_spec, details: ^details}}} =
               Workflows.run(sid, spec, workspace: ws, write_policy: policy)
    end

    assert {:error, %{error: %{kind: :invalid_spec}}} =
             Workflows.dry_run(apply_workflow("applied.txt"), workspace: ws)
  end

  test "apply starts on a completed producer and fails structurally without virtual_diff", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} = workflow_policy(["applied.txt"])

    spec =
      update_in(apply_workflow("applied.txt"), ["steps"], fn [propose, apply] ->
        [Map.put(propose, "timeout_ms", 1), apply]
      end)

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts ->
                 Process.sleep(100)
                 {:ok, add_artifact("applied.txt", "late\n")}
               end,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert [producer, apply] = result["steps"]
    assert producer["status"] == "timed_out"
    refute producer["checkpoint_status"] == "checkpoint_ready"

    # The apply_from dependency deliberately gates on completion, not on
    # checkpoint_ready: the apply runs and fails with a producer-specific
    # structured reason instead of holding as dependency_not_checkpoint_ready.
    assert apply["status"] == "failed"
    assert apply["virtual_diff_apply"]["reason"] == "producer_did_not_yield_virtual_diff"
    refute File.exists?(Path.join(ws, "applied.txt"))
  end

  test "run applies virtual_diff evidence byte-exact", %{sid: sid, ws: ws} do
    {:ok, policy} = workflow_policy(["applied.txt"])
    content = "landed from apply\n"
    artifact = add_artifact("applied.txt", content)

    assert {:ok, result} =
             Workflows.run(sid, apply_workflow("applied.txt"),
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert File.read!(Path.join(ws, "applied.txt")) == content

    assert [producer, %{"virtual_diff_apply" => %{"status" => "applied"}} = apply] =
             result["steps"]

    # Virtual-overlay and apply steps run under the policy without spawning a
    # subagent, so they have no child Log to fold — and still owe the confession.
    # A coordinator reading the durable checkpoint must never have to tell an
    # absent key apart from a step that was never gated.
    for step <- [producer, apply] do
      assert [%{"schema_id" => "workflow_checkpoint.v1", "payload" => payload}] =
               step["checkpoint"]["typed_payloads"]

      assert payload["write_denials"] == %{"count" => 0, "denials" => []},
             "#{step["id"]} (#{step["posture"]}) dropped write_denials"
    end
  end

  test "apply_from conflict keeps target untouched with engine evidence", %{sid: sid, ws: ws} do
    File.write!(Path.join(ws, "source.txt"), "current\n")
    {:ok, policy} = workflow_policy(["source.txt"])
    artifact = modify_artifact("source.txt", "stale\n", "new\n")

    assert {:ok, result} =
             Workflows.run(sid, apply_workflow("source.txt"),
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "partial"
    assert File.read!(Path.join(ws, "source.txt")) == "current\n"
    assert [_producer, apply] = result["steps"]
    assert apply["checkpoint_status"] == "failed"
    assert apply["virtual_diff_apply"]["status"] in ["conflicted", "not_applied"]
  end

  test "apply_from step write_set bounds artifact paths before engine", %{sid: sid, ws: ws} do
    {:ok, policy} = workflow_policy(["allowed.txt", "outside.txt"])
    artifact = add_artifact("outside.txt", "nope\n")

    assert {:ok, result} =
             Workflows.run(sid, apply_workflow("allowed.txt"),
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    refute File.exists?(Path.join(ws, "outside.txt"))
    assert [_producer, apply] = result["steps"]
    assert apply["virtual_diff_apply"]["reason"] == "artifact_path_outside_step_write_set"
  end

  test "bounded_write rejects writer posture read-only agents but allows read-only posture", %{
    ws: ws
  } do
    {:ok, policy} = workflow_policy(["notes.txt"])

    writer_spec = %{
      "steps" => [
        %{
          "id" => "bad",
          "task" => "write",
          "agent" => "explorer",
          "permission_mode" => "auto",
          "write_set" => ["notes.txt"]
        }
      ]
    }

    assert {:error, %{error: %{kind: :invalid_spec, details: details}}} =
             Workflows.dry_run(writer_spec, workspace: ws, write_policy: policy)

    assert details["location"] == "/steps/0/agent"
    assert details["role"] == "explorer"
    assert details["role_sandbox_mode"] == "read-only"
    assert details["mode"] == "bounded_write"

    assert {:ok, plan} =
             Workflows.dry_run(
               %{"steps" => [%{"id" => "ok", "task" => "read", "agent" => "explorer"}]},
               workspace: ws,
               write_policy: policy
             )

    assert [%{"posture" => "read_only"}] = plan["would_run"]
  end

  test "malformed nested values return structured invalid_args", %{ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => %{}, "task" => "bad"}
                 ]
               },
               workspace: ws
             )
  end

  test "dry_run exposes workflow step runtime knobs without attachment paths", %{ws: ws} do
    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{
                     "id" => "knobbed",
                     "task" => "inspect knobs",
                     "agent" => "explorer",
                     "model" => "gpt-4.1-mini",
                     "reasoning_effort" => "high",
                     "attachments" => ["source.txt", "notes/context.md"]
                   }
                 ]
               },
               workspace: ws
             )

    assert [step] = plan["would_run"]
    assert step["model"] == "gpt-4.1-mini"
    assert step["reasoning_effort"] == "high"
    assert step["attachment_count"] == 2
    refute Map.has_key?(step, "attachments")
    refute inspect(step) =~ "source.txt"
    refute inspect(step) =~ "notes/context.md"
  end

  test "dry_run omits runtime knob keys for ordinary steps", %{ws: ws} do
    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "plain", "task" => "plain task", "agent" => "explorer"}
                 ]
               },
               workspace: ws
             )

    assert [step] = plan["would_run"]
    refute Map.has_key?(step, "model")
    refute Map.has_key?(step, "reasoning_effort")
    refute Map.has_key?(step, "attachment_count")
    refute Map.has_key?(step, "attachments")
  end

  test "dry_run rejects invalid reasoning_effort with step id and vocabulary", %{ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{
                     "id" => "bad_effort",
                     "task" => "bad effort",
                     "reasoning_effort" => "ultra"
                   }
                 ]
               },
               workspace: ws
             )

    assert details["id"] == "bad_effort"
    assert details["field"] == "reasoning_effort"
    assert details["allowed"] == ~w(low medium high xhigh max)
  end

  test "runtime admission ignores top-level model and effort opts just like child spawning", %{
    sid: sid,
    ws: ws
  } do
    spec = %{"steps" => [%{"id" => "effort", "task" => "inspect", "agent" => "explorer"}]}

    assert {:ok, %{"status" => "completed"}} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: EchoProvider,
               model: "gpt-6-astra",
               reasoning_effort: "max",
               provider_opts: [test_pid: self(), model: "gpt-5.5", reasoning_effort: "high"]
             )

    assert_receive {:workflow_knobs, "gpt-5.5", "high"}
  end

  test "workflow capability errors identify the incompatible step", %{ws: ws} do
    spec = %{
      "steps" => [
        %{
          "id" => "wrong_model",
          "task" => "inspect",
          "agent" => "explorer",
          "model" => "gpt-5.5",
          "reasoning_effort" => "max"
        }
      ]
    }

    assert {:error, %{error: %{kind: :invalid_config, details: details}}} =
             Workflows.dry_run(spec, workspace: ws)

    assert details["id"] == "wrong_model"
    assert details[:reason] == :unsupported_reasoning_effort
  end

  test "workflow default remains invalid rather than silently inheriting Config intent", %{ws: ws} do
    spec = %{
      "steps" => [
        %{"id" => "invalid_default", "task" => "inspect", "reasoning_effort" => "default"}
      ]
    }

    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Workflows.dry_run(spec, workspace: ws)

    assert details["field"] == "reasoning_effort"
  end

  test "dry_run rejects invalid workflow step attachments", %{ws: ws} do
    for attachments <- ["source.txt", [""]] do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               Workflows.dry_run(
                 %{
                   "steps" => [
                     %{
                       "id" => "bad_attachments",
                       "task" => "bad attachments",
                       "attachments" => attachments
                     }
                   ]
                 },
                 workspace: ws
               )

      assert details["id"] == "bad_attachments"
      assert details["field"] == "attachments"
    end
  end

  test "run threads workflow step model, reasoning_effort, and attachments through child opts",
       %{
         sid: sid,
         ws: ws
       } do
    File.write!(Path.join(ws, "source.txt"), "attachment sentinel")

    assert {:ok, result} =
             Workflows.run(
               sid,
               %{
                 "steps" => [
                   %{
                     "id" => "knobbed",
                     "task" => "inspect knobs",
                     "agent" => "explorer",
                     "model" => "gpt-4.1-mini",
                     "reasoning_effort" => "high",
                     "attachments" => ["source.txt"]
                   }
                 ]
               },
               workspace: ws,
               provider: EchoProvider,
               provider_opts: [test_pid: self()],
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert [request] = collect_requests(1)
    assert_received {:workflow_knobs, "gpt-4.1-mini", "high"}
    refute request.developer_context =~ ~s("model")
    refute request.developer_context =~ ~s("reasoning_effort")
    refute request.developer_context =~ ~s("attachments")

    # The attachment must reach the child as a durable Session Resource: the
    # child Log's user_message carries the ingested descriptor, proving the
    # opts channel threaded end to end (not just that validation passed).
    assert [%{"child_session_id" => child_sid}] = result["steps"]
    assert is_binary(child_sid)
    assert {:ok, child_history} = Log.fold(child_sid, workspace: ws)
    user_message = Enum.find(child_history, &(&1.type == :user_message))
    assert [resource] = user_message.data["resources"]
    assert resource["name"] == "source.txt"
  end

  test "step knobs ride subagent opts and never spawn args", %{sid: sid, ws: ws} do
    File.write!(Path.join(ws, "source.txt"), "sentinel")
    test_pid = self()

    spawn_agent = fn parent_sid, args, opts ->
      send(test_pid, {:spawn_seam, args, opts})
      Pixir.Subagents.spawn_agent(parent_sid, args, opts)
    end

    assert {:ok, %{"status" => "completed"}} =
             Workflows.run(
               sid,
               %{
                 "steps" => [
                   %{
                     "id" => "knobbed",
                     "task" => "inspect",
                     "agent" => "explorer",
                     "model" => "gpt-4.1-mini",
                     "reasoning_effort" => "high",
                     "attachments" => ["source.txt"]
                   }
                 ]
               },
               workspace: ws,
               provider: EchoProvider,
               provider_opts: [test_pid: self()],
               spawn_agent: spawn_agent,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert_received {:spawn_seam, args, opts}
    refute Map.has_key?(args, "model")
    refute Map.has_key?(args, "reasoning_effort")
    refute Map.has_key?(args, "attachments")
    assert Keyword.get(opts, :model) == "gpt-4.1-mini"
    assert Keyword.get(opts, :reasoning_effort) == "high"
    assert [%{"type" => "resource_link"}] = Keyword.get(opts, :attachments)
    refute Keyword.has_key?(opts, :spawn_agent)
  end

  test "inherited caller opts never reach knobless steps", %{sid: sid, ws: ws} do
    test_pid = self()

    spawn_agent = fn parent_sid, args, opts ->
      send(test_pid, {:spawn_seam, args, opts})
      Pixir.Subagents.spawn_agent(parent_sid, args, opts)
    end

    assert {:ok, %{"status" => "completed"}} =
             Workflows.run(
               sid,
               %{"steps" => [%{"id" => "plain", "task" => "t", "agent" => "explorer"}]},
               workspace: ws,
               provider: EchoProvider,
               provider_opts: [test_pid: self()],
               spawn_agent: spawn_agent,
               model: "from-parent",
               reasoning_effort: "xhigh",
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert_received {:spawn_seam, _args, opts}
    refute Keyword.has_key?(opts, :model)
    refute Keyword.has_key?(opts, :reasoning_effort)
    refute Keyword.has_key?(opts, :attachments)
  end

  test "virtual_overlay steps reject the knobs the run would ignore", %{ws: _ws} do
    spec = %{
      "steps" => [
        %{
          "id" => "scratch",
          "task" => "t",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["a"],
          "virtual_commands" => ["true"],
          "model" => "gpt-x"
        }
      ]
    }

    assert {:error, %{error: %{kind: :invalid_args, message: message, details: details}}} =
             Workflows.dry_run(spec)

    assert message =~ "virtual_overlay workflow steps do not take"
    assert details["id"] == "scratch"
  end

  test "run schedules subagents and feeds dependency summaries", %{sid: sid, ws: ws} do
    spec = dependency_workflow()

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: EchoProvider,
               provider_opts: [test_pid: self()],
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert result["proof_states"] == Workflows.proof_states()
    assert result["completed_order"] == nil
    assert Enum.map(result["steps"], & &1["id"]) == ["inspect_a", "inspect_b", "summarize"]
    assert result["waves"] == [["inspect_a", "inspect_b"], ["summarize"]]

    prompts = collect_prompts(3)
    summarize_prompt = Enum.find(prompts, &String.contains?(&1, "Step: summarize"))
    assert summarize_prompt =~ "Output contract:"
    assert summarize_prompt =~ "checkpoint_status: checkpoint_ready"
    assert summarize_prompt =~ "checkpoint_status: needs_orchestrator"
    assert summarize_prompt =~ "Do not spawn further Subagents unless"
    assert summarize_prompt =~ "Dependency results:"
    assert summarize_prompt =~ "- inspect_a: summary:inspect_a"
    assert summarize_prompt =~ "- inspect_b: summary:inspect_b"

    requests = collect_requests(3)

    summarize_request =
      Enum.find(requests, &String.contains?(&1.developer_context, ~s("step_id": "summarize")))

    assert summarize_request.developer_context =~ "Subagent delegation context"
    assert summarize_request.developer_context =~ ~s("workflow_id": "deps")
    assert summarize_request.developer_context =~ ~s("workflow_name": "Dependency workflow")
    assert summarize_request.developer_context =~ ~s("step_id": "summarize")
    assert summarize_request.developer_context =~ ~s("wave": 2)
    assert summarize_request.developer_context =~ "inspect_a"
    assert summarize_request.developer_context =~ "summary:inspect_a"
    assert summarize_request.developer_context =~ "inspect_b"
    assert summarize_request.developer_context =~ "summary:inspect_b"
    assert summarize_request.developer_context =~ ~s("posture": "read_only")
    assert summarize_request.developer_context =~ "checkpoint_ready"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished")) ==
             3

    refute Enum.any?(history, &(&1.type == :subagent_event and Map.has_key?(&1.data, "index")))
    refute Enum.any?(result["steps"], &Map.has_key?(&1, "index"))

    workflow_events = workflow_events(history)
    kinds = Enum.map(workflow_events, & &1.data["kind"])

    assert hd(kinds) == "workflow_started"
    assert List.last(kinds) == "workflow_finished"
    assert Enum.count(kinds, &(&1 == "step_scheduled")) == 3
    assert Enum.count(kinds, &(&1 == "checkpoint_decided")) == 3

    assert Enum.all?(result["usable_checkpoints"], fn checkpoint ->
             checkpoint["version"] == 2 and
               match?(
                 [
                   %{
                     "schema_id" => "workflow_checkpoint.v1",
                     "provenance" => "harness_projection",
                     "validation" => %{"status" => "valid"}
                   }
                 ],
                 checkpoint["typed_payloads"]
               ) and checkpoint["artifacts"] == []
           end)

    assert %{"status" => "completed", "ok" => true} = List.last(workflow_events).data
  end

  test "run executes virtual_overlay step and returns not-applied virtual_diff", %{
    sid: sid,
    ws: ws
  } do
    source_path = Path.join(ws, "source.txt")
    original_parent = File.read!(source_path)

    spec = %{
      "id" => "virtual_runtime",
      "steps" => [
        %{
          "id" => "scratch",
          "task" => "scratch edit without parent mutation",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => [
            "sed -i 's/workflow/virtual/' source.txt",
            "grep virtual source.txt"
          ]
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: EchoProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert result["summary"]["virtual_overlay_steps"] == 1
    assert [%{"id" => "scratch"} = step] = result["steps"]
    assert step["workspace_mode"] == "virtual_overlay"
    assert step["posture"] == "virtual_scratch"
    assert step["subagent_status"] == "not_applicable"
    assert step["checkpoint_status"] == "checkpoint_ready"
    assert step["summary"] =~ "virtual_overlay produced virtual_diff"
    assert step["summary"] =~ "apply_status=not_applied"

    artifact = step["virtual_diff"]
    assert artifact["kind"] == "virtual_diff"
    assert artifact["workspace_strategy"] == "virtual_overlay"
    assert artifact["workspace_fidelity"] == "virtual_shell_no_host_binaries"
    assert artifact["parent_workspace"]["mutation"] == "none"
    assert artifact["apply"]["status"] == "not_applied"
    assert artifact["apply"]["requires_explicit_apply"] == true
    expected_commands = spec["steps"] |> hd() |> Map.fetch!("virtual_commands")
    assert Enum.map(artifact["commands"], & &1["display"]) == expected_commands

    change = Enum.find(artifact["changes"], &(&1["path"] == "source.txt"))
    assert change["operation"] == "modify"
    assert change["diff"]["text"] =~ "-workflow source"
    assert change["diff"]["text"] =~ "+virtual source"

    assert [checkpoint] = result["usable_checkpoints"]
    assert checkpoint["version"] == 2
    assert checkpoint["virtual_diff"]["apply"]["status"] == "not_applied"
    assert checkpoint["verification"]["source"] == "virtual_overlay_runner"
    assert checkpoint["verification"]["parent_workspace_mutation"] == "none"
    assert checkpoint["verification"]["apply_status"] == "not_applied"
    assert "virtual_diff_not_applied" in checkpoint["known_limitations"]

    assert [%{"kind" => "virtual_diff", "provenance" => "artifact"} = artifact_ref] =
             checkpoint["artifacts"]

    assert is_binary(artifact_ref["hash"])
    assert artifact_ref["schema_id"] == "artifact_ref.v1"
    assert artifact_ref["validation"]["status"] == "valid"
    assert [%{"schema_id" => "workflow_checkpoint.v1"}] = checkpoint["typed_payloads"]

    assert File.read!(source_path) == original_parent

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :subagent_event))

    workflow_events = workflow_events(history)

    assert Enum.map(workflow_events, & &1.data["kind"]) == [
             "workflow_started",
             "step_scheduled",
             "checkpoint_decided",
             "workflow_finished"
           ]

    checkpoint_event = Enum.find(workflow_events, &(&1.data["kind"] == "checkpoint_decided"))
    assert checkpoint_event.data["checkpoint"]["typed_schema_ids"] == ["workflow_checkpoint.v1"]
    assert [%{"kind" => "virtual_diff"}] = checkpoint_event.data["checkpoint"]["artifact_refs"]
  end

  test "run times out slow virtual_overlay steps", %{sid: sid, ws: ws} do
    slow_runner = fn _workspace, _params, _opts ->
      Process.sleep(1_000)
      {:ok, %{}}
    end

    spec = %{
      "id" => "virtual_timeout",
      "steps" => [
        %{
          "id" => "slow_virtual",
          "task" => "slow virtual command",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => ["cat source.txt"],
          "timeout_ms" => 10
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               virtual_overlay_runner: slow_runner,
               timeout_ms: 5_000
             )

    assert result["status"] == "partial"
    assert [%{"id" => "slow_virtual"} = step] = result["failed_steps"]
    assert [%{"id" => "slow_virtual"}] = result["timeout_steps"]
    assert step["status"] == "timed_out"
    assert step["checkpoint_status"] == "failed"
    assert step["workspace_mode"] == "virtual_overlay"
    assert step["reason"] == "step_timeout"
    assert step["timeout_ms"] == 10
    assert step["checkpoint"]["verification"]["reason"] == "step_timeout"
    assert "virtual_overlay_timeout" in step["checkpoint"]["known_limitations"]
  end

  test "run returns partial workflow data for failed steps and held dependents", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} =
      WritePolicy.normalize(%{
        "version" => 1,
        "metadata" => %{"id" => "partial-workflow-policy"},
        "allow_writes" => ["scratch/**"]
      })

    spec = %{
      "id" => "partial_failure",
      "max_concurrency" => 2,
      "steps" => [
        %{"id" => "ready", "task" => "ready", "agent" => "explorer"},
        %{"id" => "fail", "task" => "fail", "agent" => "explorer"},
        %{
          "id" => "after_ready",
          "task" => "after ready",
          "agent" => "explorer",
          "depends_on" => ["ready"]
        },
        %{
          "id" => "held",
          "task" => "held",
          "agent" => "explorer",
          "depends_on" => ["fail"]
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: PartialProvider,
               poll_ms: 10,
               timeout_ms: 5_000,
               write_policy: policy
             )

    assert result["ok"] == false
    assert result["status"] == "partial"
    assert result["proof_states"] == Workflows.partial_proof_states()
    assert Enum.map(result["usable_checkpoints"], & &1["step_id"]) == ["ready", "after_ready"]
    assert [%{"id" => "fail", "checkpoint_status" => "failed"}] = result["failed_steps"]
    assert [%{"id" => "held", "checkpoint_status" => "held"}] = result["held_steps"]
    assert "retry_failed_steps" in result["safe_next_actions"]

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    workflow_events = workflow_events(history)
    kinds = Enum.map(workflow_events, & &1.data["kind"])

    assert Enum.count(kinds, &(&1 == "step_held")) == 1
    assert Enum.count(kinds, &(&1 == "checkpoint_decided")) == 4

    held_event = Enum.find(workflow_events, &(&1.data["kind"] == "step_held"))
    assert held_event.data["write_policy"]["id"] == "partial-workflow-policy"

    checkpoint_events =
      Enum.filter(workflow_events, &(&1.data["kind"] == "checkpoint_decided"))

    assert Enum.all?(
             checkpoint_events,
             &(&1.data["write_policy"]["id"] == "partial-workflow-policy")
           )

    assert %{"kind" => "workflow_finished", "status" => "partial", "ok" => false} =
             List.last(workflow_events).data
  end

  test "partial checkpoint status does not unblock dependent steps", %{sid: sid, ws: ws} do
    spec = %{
      "id" => "partial_checkpoint",
      "steps" => [
        %{"id" => "partial", "task" => "partial", "agent" => "explorer"},
        %{
          "id" => "blocked",
          "task" => "blocked",
          "agent" => "explorer",
          "depends_on" => ["partial"]
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: PartialProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "partial"
    assert [%{"id" => "partial", "checkpoint_status" => "partial"}] = result["partial_steps"]
    assert [%{"id" => "blocked", "checkpoint_status" => "held"}] = result["held_steps"]
  end

  test "held virtual_overlay steps retain workspace mode for summaries", %{sid: sid, ws: ws} do
    spec = %{
      "id" => "held_virtual",
      "steps" => [
        %{"id" => "fail", "task" => "fail", "agent" => "explorer"},
        %{
          "id" => "blocked_virtual",
          "task" => "blocked virtual",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => ["cat source.txt"],
          "depends_on" => ["fail"]
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: PartialProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "partial"
    assert result["summary"]["virtual_overlay_steps"] == 1
    assert [%{"id" => "blocked_virtual"} = held] = result["held_steps"]
    assert held["workspace_mode"] == "virtual_overlay"
  end

  test "workflow-level timeout cancels active subagents before returning partial", %{
    sid: sid,
    ws: ws
  } do
    spec = %{
      "id" => "workflow_timeout",
      "max_concurrency" => 1,
      "timeout_ms" => 1_000,
      "steps" => [
        %{
          "id" => "slow_writer",
          "task" => "slow writer",
          "agent" => "worker",
          "timeout_ms" => 5_000
        },
        %{
          "id" => "pending_reader",
          "task" => "pending reader",
          "agent" => "explorer"
        }
      ]
    }

    test_pid = self()

    task =
      Task.async(fn ->
        Workflows.run(sid, spec,
          workspace: ws,
          provider: BlockingProvider,
          provider_opts: [test_pid: test_pid],
          poll_ms: 10
        )
      end)

    assert_receive {:blocking_provider_started, _pid}, 1_000
    assert {:ok, result} = Task.await(task, 3_000)

    assert result["status"] == "partial"
    assert [%{"id" => "slow_writer"} = failed] = result["failed_steps"]
    assert [%{"id" => "pending_reader"} = held] = result["held_steps"]
    assert [%{"id" => "slow_writer"}] = result["timeout_steps"]
    assert result["summary"]["timeout_steps"] == 1
    assert "inspect_timed_out_steps_or_retry_with_larger_timeout" in result["safe_next_actions"]

    assert failed["status"] == "timed_out"
    assert failed["subagent_status"] == "cancelled"
    assert failed["timeout_ms"] == 5_000
    assert failed["workflow_timeout_ms"] == 1_000
    assert failed["step_timeout_ms"] == 5_000
    assert is_integer(failed["elapsed_ms"])
    assert failed["reason"] == "closed_by_workflow_timeout"
    assert "retry_workflow_with_larger_timeout" in failed["next_actions"]

    assert failed["checkpoint"]["verification"]["workflow_timeout_action"] ==
             "closed_by_workflow_timeout"

    assert failed["checkpoint"]["verification"]["timeout_ms"] == 5_000
    assert failed["checkpoint"]["verification"]["workflow_timeout_ms"] == 1_000
    assert failed["checkpoint"]["verification"]["step_timeout_ms"] == 5_000
    assert is_integer(failed["checkpoint"]["verification"]["elapsed_ms"])
    assert failed["checkpoint"]["verification"]["reason"] == "closed_by_workflow_timeout"

    assert held["held_reason"] == "workflow_timeout"
    assert held["checkpoint"]["known_limitations"] == ["workflow_timeout"]
    assert held["safe_next_actions"] == ["retry_workflow_with_larger_timeout"]

    assert [%{"payload" => %{"known_limitations" => ["workflow_timeout"]}}] =
             held["checkpoint"]["typed_payloads"]

    assert {:ok, [agent]} = Subagents.list(sid, workspace: ws)
    assert agent["status"] == "cancelled"

    # Every child cancelled by the deadline names that workflow in its own Log.
    child_sid = agent["child_session_id"]
    assert is_binary(child_sid)
    assert {:ok, child_history} = Log.fold(child_sid, workspace: agent["workspace"])

    assert [terminal] =
             Enum.filter(
               child_history,
               &(&1.type == :subagent_event and &1.data["event"] == "cancelled_by_parent")
             )

    assert terminal.data["reason"] == "cancelled_by_parent"
    assert terminal.data["lineage"] == "child"
    assert terminal.data["parent_session_id"] == sid
    assert terminal.data["subagent_id"] == agent["id"]
    assert terminal.data["workflow_id"] == "workflow_timeout"
    assert terminal.data["workflow_step_id"] == "slow_writer"
    assert terminal.data["workflow_close_outcome"] == "closed_by_workflow_timeout"
    assert List.last(child_history).seq == terminal.seq
  end

  test "rejects unknown dependencies and cycles", %{ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "a", "task" => "A", "depends_on" => ["missing"]}
                 ]
               },
               workspace: ws
             )

    assert {:error, %{error: %{kind: :invalid_args}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "a", "task" => "A", "depends_on" => ["b"]},
                   %{"id" => "b", "task" => "B", "depends_on" => ["a"]}
                 ]
               },
               workspace: ws
             )
  end

  test "rejects ambiguous workspace modes", %{ws: ws} do
    assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{"id" => "a", "task" => "A", "workspace_mode" => "parent"}
                 ]
               },
               workspace: ws
             )

    assert details["id"] == "a"
    assert details["workspace_mode"] == "parent"
    assert details["supported_modes"] == ["shared", "isolated", "virtual_overlay"]
    assert details["future_modes"] == []
  end

  test "rejects malformed virtual_overlay step boundaries", %{ws: ws} do
    invalid_steps = [
      {%{
         "id" => "missing_read_set",
         "task" => "missing read_set",
         "workspace_mode" => "virtual_overlay",
         "virtual_commands" => ["cat source.txt"]
       }, "read_set"},
      {%{
         "id" => "wildcard_read_set",
         "task" => "wildcard read_set",
         "workspace_mode" => "virtual_overlay",
         "read_set" => ["**/*"],
         "virtual_commands" => ["find . -type f"]
       }, "read_set"},
      {%{
         "id" => "missing_commands",
         "task" => "missing commands",
         "workspace_mode" => "virtual_overlay",
         "read_set" => ["source.txt"]
       }, "virtual_commands"},
      {%{
         "id" => "shared_commands",
         "task" => "wrong commands",
         "workspace_mode" => "shared",
         "virtual_commands" => ["cat source.txt"]
       }, "virtual_commands"}
    ]

    for {step, field} <- invalid_steps do
      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               Workflows.dry_run(%{"steps" => [step]}, workspace: ws)

      assert details["id"] == step["id"]
      assert details["field"] == field
    end
  end

  test "Workflow derives read_set acceptance from the shared classifier", %{ws: ws} do
    aliases = [
      Path.join(ws, "**/*"),
      "../#{Path.basename(ws)}/**/*",
      "././**/**/**/*",
      "lib/../**/*",
      "**/**/**/*"
    ]

    for alias_entry <- aliases do
      step = %{
        "id" => "classified_read_set",
        "task" => "classify read set",
        "workspace_mode" => "virtual_overlay",
        "read_set" => ["source.txt", alias_entry],
        "virtual_commands" => ["true"]
      }

      assert {:error, %{error: %{kind: :invalid_args, details: details}}} =
               Workflows.dry_run(%{"steps" => [step]}, workspace: ws)

      assert details["id"] == "classified_read_set"
      assert details["field"] == "read_set"
      assert details["index"] == 1

      assert details["reason"] in [
               "absolute_path",
               "parent_component",
               "root_recursive_catch_all"
             ]
    end

    assert {:ok, plan} =
             Workflows.dry_run(
               %{
                 "steps" => [
                   %{
                     "id" => "bounded_read_set",
                     "task" => "accept bounded patterns",
                     "workspace_mode" => "virtual_overlay",
                     "read_set" => [
                       "lib/**/*",
                       "**/*.ex",
                       "./lib/**/*",
                       "lib/**/test_*.exs"
                     ],
                     "virtual_commands" => ["true"]
                   }
                 ]
               },
               workspace: ws
             )

    assert [step] = plan["would_run"]

    assert step["read_set"] == [
             "lib/**/*",
             "**/*.ex",
             "./lib/**/*",
             "lib/**/test_*.exs"
           ]
  end

  test "abnormal virtual_overlay runner exits return a structured workflow error", %{
    sid: sid,
    ws: ws
  } do
    spec = %{
      "steps" => [
        %{
          "id" => "crashing_virtual",
          "task" => "exercise runner exit handling",
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["source.txt"],
          "virtual_commands" => ["true"]
        }
      ]
    }

    assert {:error, %{error: %{kind: :command_failed, details: details}}} =
             Workflows.run(sid, spec,
               workspace: ws,
               virtual_overlay_runner: fn _workspace, _params, _opts -> exit(:runner_boom) end,
               timeout_ms: 5_000
             )

    assert details["reason"] == "virtual_overlay_runner_task_exit"
    assert details["exit_reason"] =~ "runner_boom"
  end

  test "abnormal virtual_diff apply task exits complete as a failed apply step", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} = workflow_policy(["applied.txt"])
    artifact = add_artifact("applied.txt", "not applied\n")

    assert {:ok, result} =
             Workflows.run(sid, apply_workflow("applied.txt"),
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
               virtual_diff_apply_runner: fn _artifact, _workspace, _opts ->
                 exit(:apply_boom)
               end,
               timeout_ms: 5_000
             )

    assert [_producer, apply] = result["steps"]
    assert apply["status"] == "failed"
    assert apply["virtual_diff_apply"]["reason"] == "virtual_diff_apply_task_exit"
    assert apply["virtual_diff_apply"]["details"]["exit_reason"] =~ "apply_boom"
    refute File.exists?(Path.join(ws, "applied.txt"))
  end

  test "interrupt tears down a blocked write-capable apply task", %{sid: sid, ws: ws} do
    {:ok, policy} = workflow_policy(["applied.txt"])
    artifact = add_artifact("applied.txt", "must not land after interrupt\n")
    test_pid = self()

    assert {:ok, _turn_ref} =
             Session.start_turn(sid, fn _ctx ->
               Workflows.run(sid, apply_workflow("applied.txt"),
                 workspace: ws,
                 write_policy: policy,
                 virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
                 virtual_diff_apply_runner: fn _artifact, workspace, _opts ->
                   send(test_pid, {:blocked_apply_started, self()})

                   receive do
                     :mutate_after_interrupt ->
                       File.write!(Path.join(workspace, "applied.txt"), "late mutation\n")
                       {:ok, %{"status" => "applied"}}
                   end
                 end,
                 timeout_ms: 5_000
               )
             end)

    assert_receive {:blocked_apply_started, apply_pid}, 1_000
    apply_ref = Process.monitor(apply_pid)

    on_exit(fn ->
      if Process.alive?(apply_pid), do: Process.exit(apply_pid, :kill)
    end)

    assert Process.alive?(apply_pid)
    assert :ok = Session.interrupt(sid)
    assert_receive {:DOWN, ^apply_ref, :process, ^apply_pid, _reason}, 1_000
    refute Process.alive?(apply_pid)

    # A sibling async_nolink task would still receive this and mutate the parent
    # workspace. The interrupt-coupled task is already dead, so the write cannot land.
    send(apply_pid, :mutate_after_interrupt)
    Process.sleep(20)
    refute File.exists?(Path.join(ws, "applied.txt"))
  end

  test "apply_from handles a final symlink artifact path without raising", %{sid: sid, ws: ws} do
    outside = Path.join(System.tmp_dir!(), "pixir-workflow-final-link-#{System.unique_integer()}")
    File.write!(outside, "outside\n")
    File.ln_s!(outside, Path.join(ws, "link.txt"))
    on_exit(fn -> File.rm(outside) end)

    {:ok, policy} = workflow_policy(["link.txt"])

    artifact = %{
      "kind" => "virtual_diff",
      "version" => 1,
      "changes" => [
        %{
          "path" => "link.txt",
          "operation" => "delete",
          "before" => %{"sha256" => sha256("outside\n")},
          "diff" => %{"truncated" => false}
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, apply_workflow("link.txt"),
               workspace: ws,
               write_policy: policy,
               virtual_overlay_runner: fn _workspace, _params, _opts -> {:ok, artifact} end,
               timeout_ms: 5_000
             )

    assert [_producer, apply] = result["steps"]
    assert apply["status"] == "failed"
    assert apply["virtual_diff_apply"]["status"] == "not_applied"
    assert [%{"status" => "outside_workspace"}] = apply["virtual_diff_apply"]["files"]
    assert File.read!(outside) == "outside\n"
  end

  test "workflow virtual path does not introduce host-boundary calls" do
    source = File.read!("lib/pixir/workflows.ex")

    refute source =~ "System.cmd"
    refute source =~ "Port.open"
    refute source =~ ":os.cmd"
    refute source =~ "System.find_executable"
    refute source =~ "CommandBoundary"
    refute source =~ "/bin/bash"
    refute source =~ "/bin/sh"
  end

  # ── write_denials confession (#446) ────────────────────────────────────────

  defp denial_workflow_spec do
    %{
      "id" => "write_denials",
      "steps" => [
        %{
          "id" => "writer",
          "task" => "write inside the allowlist",
          "write_set" => ["notes.txt"]
        }
      ]
    }
  end

  test "a step that recovered from a denial still reaches checkpoint_ready and confesses it", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} = workflow_policy(["notes.txt"])

    assert {:ok, result} =
             Workflows.run(sid, denial_workflow_spec(),
               workspace: ws,
               write_policy: policy,
               provider: DeniedWriteProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert [step] = result["steps"]
    assert step["checkpoint_status"] == "checkpoint_ready"
    refute File.exists?(Path.join(ws, "outside.txt"))

    assert [%{"schema_id" => "workflow_checkpoint.v1", "payload" => payload}] =
             step["checkpoint"]["typed_payloads"]

    confession = payload["write_denials"]
    assert confession, "the checkpoint payload must always carry write_denials"
    assert confession["count"] == 1

    assert [denial] = confession["denials"]
    assert denial["tool"] == "write"
    assert denial["normalized_path"] == "outside.txt"
    assert denial["matched_rule"] == "no_allow_match"
    assert denial["disposition"] == "recovered"
  end

  test "a bounded-write step with no denial still carries an empty write_denials", %{
    sid: sid,
    ws: ws
  } do
    {:ok, policy} = workflow_policy(["notes.txt"])

    assert {:ok, result} =
             Workflows.run(sid, denial_workflow_spec(),
               workspace: ws,
               write_policy: policy,
               provider: EchoProvider,
               poll_ms: 10,
               timeout_ms: 5_000
             )

    assert result["status"] == "completed"
    assert [step] = result["steps"]

    assert [%{"schema_id" => "workflow_checkpoint.v1", "payload" => payload}] =
             step["checkpoint"]["typed_payloads"]

    assert payload["write_denials"] == %{"count" => 0, "denials" => []}
  end

  # The confession is mandatory on the `workflow_checkpoint.v1` projection of
  # EVERY bounded-write step, not only the ones that ran a subagent to
  # completion. A held step never spawned a child and so has nothing to confess,
  # but "nothing to confess" is a zero count, not a missing key: absence is
  # defined as a schema violation, and a coordinator reading a durable
  # checkpoint cannot tell an absent key from a step that was never gated.
  test "a held bounded-write step still carries an empty write_denials", %{sid: sid, ws: ws} do
    {:ok, policy} = workflow_policy(["scratch/**"])

    spec = %{
      "id" => "held_confession",
      "max_concurrency" => 2,
      "steps" => [
        %{"id" => "ready", "task" => "ready", "agent" => "explorer"},
        %{"id" => "fail", "task" => "fail", "agent" => "explorer"},
        %{
          "id" => "held",
          "task" => "held",
          "agent" => "explorer",
          "depends_on" => ["fail"]
        }
      ]
    }

    assert {:ok, result} =
             Workflows.run(sid, spec,
               workspace: ws,
               provider: PartialProvider,
               poll_ms: 10,
               timeout_ms: 5_000,
               write_policy: policy
             )

    assert [held] = result["held_steps"]
    assert held["checkpoint_status"] == "held"

    assert [%{"schema_id" => "workflow_checkpoint.v1", "payload" => payload}] =
             held["checkpoint"]["typed_payloads"]

    assert payload["write_denials"] == %{"count" => 0, "denials" => []},
           "a held bounded-write step must confess an empty write_denials"

    # The failed and completed steps of the same run carry it too: every
    # bounded-write checkpoint projection does, whatever the status.
    for step <- result["steps"] do
      assert [%{"payload" => step_payload}] = step["checkpoint"]["typed_payloads"]

      assert step_payload["write_denials"],
             "step #{step["id"]} (#{step["checkpoint_status"]}) dropped write_denials"
    end
  end

  # ── unverified dependency basis ────────────────────────────────────────────

  describe "allow_unverified_depends_on" do
    defp audit_spec(id, audit_step_overrides) do
      %{
        "id" => id,
        "steps" => [
          %{"id" => "partial_writer", "task" => "write", "agent" => "explorer"},
          Map.merge(
            %{
              "id" => "audit",
              "task" => "audit the writer",
              "agent" => "explorer",
              "depends_on" => ["partial_writer"]
            },
            audit_step_overrides
          )
        ]
      }
    end

    defp run_marker(sid, ws, spec) do
      Workflows.run(sid, spec,
        workspace: ws,
        provider: MarkerProvider,
        poll_ms: 10,
        timeout_ms: 5_000
      )
    end

    test "an opted-in audit step schedules against a completed-but-partial dependency", %{
      sid: sid,
      ws: ws
    } do
      spec =
        audit_spec("audit_unverified", %{"allow_unverified_depends_on" => ["partial_writer"]})

      assert {:ok, result} = run_marker(sid, ws, spec)

      assert Enum.map(result["steps"], & &1["id"]) == ["partial_writer", "audit"]
      assert result["held_steps"] == []

      assert %{"id" => "audit", "checkpoint_status" => "checkpoint_ready"} =
               Enum.find(result["steps"], &(&1["id"] == "audit"))

      assert {:ok, history} = Log.fold(sid, workspace: ws)

      held =
        history
        |> workflow_events()
        |> Enum.filter(&(&1.data["kind"] == "step_held"))

      assert held == []
    end

    test "the same workflow without the opt-in still holds the audit step", %{sid: sid, ws: ws} do
      assert {:ok, result} = run_marker(sid, ws, audit_spec("audit_strict", %{}))

      assert result["status"] == "partial"
      assert [%{"id" => "audit", "checkpoint_status" => "held"} = held] = result["held_steps"]
      assert held["held_reason"] == "dependency_not_checkpoint_ready"
      assert held["checkpoint"]["known_limitations"] == ["dependency_not_checkpoint_ready"]
      assert held["safe_next_actions"] == ["rerun_after_dependencies_checkpoint_ready"]
    end

    test "the audit checkpoint bundle and typed payload record the unverified basis", %{
      sid: sid,
      ws: ws
    } do
      spec = audit_spec("audit_basis", %{"allow_unverified_depends_on" => ["partial_writer"]})

      assert {:ok, result} = run_marker(sid, ws, spec)

      audit = Enum.find(result["steps"], &(&1["id"] == "audit"))
      checkpoint = audit["checkpoint"]

      assert checkpoint["verification"]["unverified_dependencies"] == ["partial_writer"]
      assert "ran_against_unverified_dependencies" in checkpoint["known_limitations"]

      assert [%{"schema_id" => "workflow_checkpoint.v1", "payload" => payload}] =
               checkpoint["typed_payloads"]

      assert payload["unverified_dependencies"] == ["partial_writer"]
      assert "ran_against_unverified_dependencies" in payload["known_limitations"]
      assert payload["verification_source"] == "subagent_terminal_summary"
    end

    test "the opt-in never launders the upstream dependency's own status", %{sid: sid, ws: ws} do
      assert {:ok, relaxed} =
               run_marker(
                 sid,
                 ws,
                 audit_spec("audit_no_launder", %{
                   "allow_unverified_depends_on" => ["partial_writer"]
                 })
               )

      assert {:ok, strict} = run_marker(sid, ws, audit_spec("audit_no_launder_strict", %{}))

      relaxed_writer = Enum.find(relaxed["steps"], &(&1["id"] == "partial_writer"))
      strict_writer = Enum.find(strict["steps"], &(&1["id"] == "partial_writer"))

      assert relaxed_writer["checkpoint_status"] == "partial"
      assert relaxed_writer["checkpoint"]["dependent_safe"] == false
      assert relaxed_writer["checkpoint"]["known_limitations"] == ["checkpoint_not_ready"]

      assert relaxed_writer["checkpoint_status"] == strict_writer["checkpoint_status"]

      assert relaxed_writer["checkpoint"]["dependent_safe"] ==
               strict_writer["checkpoint"]["dependent_safe"]

      assert relaxed_writer["checkpoint"]["known_limitations"] ==
               strict_writer["checkpoint"]["known_limitations"]

      assert relaxed["summary"]["partial_steps"] == 1
      assert relaxed["summary"]["partial_steps"] == strict["summary"]["partial_steps"]
      assert Enum.map(relaxed["partial_steps"], & &1["id"]) == ["partial_writer"]
      assert relaxed["usable_checkpoints"] |> Enum.map(& &1["step_id"]) == ["audit"]
      assert relaxed["status"] == "partial"
    end

    for {label, producer_id} <- [
          {"a completed child self-declaring failed", "failed_writer"},
          {"a completed child self-declaring needs_orchestrator", "needs_orchestrator_writer"}
        ] do
      test "the opt-in does not admit #{label}", %{sid: sid, ws: ws} do
        producer_id = unquote(producer_id)

        spec = %{
          "id" => "audit_inadmissible_#{producer_id}",
          "steps" => [
            %{"id" => producer_id, "task" => "write", "agent" => "explorer"},
            %{
              "id" => "audit",
              "task" => "audit",
              "agent" => "explorer",
              "depends_on" => [producer_id],
              "allow_unverified_depends_on" => [producer_id]
            }
          ]
        }

        assert {:ok, result} = run_marker(sid, ws, spec)

        assert result["status"] == "partial"
        assert [%{"id" => "audit", "checkpoint_status" => "held"} = held] = result["held_steps"]
        assert held["held_reason"] == "dependency_not_checkpoint_ready"
      end
    end

    test "the opt-in does not admit a dependency whose child timed out", %{sid: sid, ws: ws} do
      spec = %{
        "id" => "audit_timeout",
        "steps" => [
          %{"id" => "slow_writer", "task" => "slow", "agent" => "explorer"},
          %{
            "id" => "audit",
            "task" => "audit",
            "agent" => "explorer",
            "depends_on" => ["slow_writer"],
            "allow_unverified_depends_on" => ["slow_writer"]
          }
        ]
      }

      test_pid = self()

      task =
        Task.async(fn ->
          Workflows.run(sid, spec,
            workspace: ws,
            provider: BlockingProvider,
            provider_opts: [test_pid: test_pid],
            timeout_ms: 1_000,
            poll_ms: 10
          )
        end)

      assert_receive {:blocking_provider_started, _pid}, 2_000
      assert {:ok, result} = Task.await(task, 5_000)

      assert result["status"] == "partial"
      assert [%{"id" => "audit", "checkpoint_status" => "held"} = held] = result["held_steps"]
      assert held["held_reason"] == "workflow_timeout"
    end

    test "the opt-in does not admit a dependency that was itself held", %{sid: sid, ws: ws} do
      spec = %{
        "id" => "audit_held_dep",
        "steps" => [
          %{"id" => "failed_root", "task" => "root", "agent" => "explorer"},
          %{
            "id" => "partial_middle",
            "task" => "middle",
            "agent" => "explorer",
            "depends_on" => ["failed_root"]
          },
          %{
            "id" => "audit",
            "task" => "audit",
            "agent" => "explorer",
            "depends_on" => ["partial_middle"],
            "allow_unverified_depends_on" => ["partial_middle"]
          }
        ]
      }

      assert {:ok, result} = run_marker(sid, ws, spec)

      assert result["status"] == "partial"

      assert ["audit", "partial_middle"] ==
               result["held_steps"] |> Enum.map(& &1["id"]) |> Enum.sort()

      audit = Enum.find(result["steps"], &(&1["id"] == "audit"))
      assert audit["held_reason"] == "dependency_not_checkpoint_ready"
    end

    test "the opt-in relaxes only the dependencies it names", %{sid: sid, ws: ws} do
      spec = %{
        "id" => "audit_partial_relax",
        "max_concurrency" => 2,
        "steps" => [
          %{"id" => "partial_named", "task" => "named", "agent" => "explorer"},
          %{"id" => "partial_unnamed", "task" => "unnamed", "agent" => "explorer"},
          %{
            "id" => "audit",
            "task" => "audit",
            "agent" => "explorer",
            "depends_on" => ["partial_named", "partial_unnamed"],
            "allow_unverified_depends_on" => ["partial_named"]
          }
        ]
      }

      assert {:ok, result} = run_marker(sid, ws, spec)

      assert result["status"] == "partial"
      assert [%{"id" => "audit", "checkpoint_status" => "held"} = held] = result["held_steps"]
      assert held["held_reason"] == "dependency_not_checkpoint_ready"
    end

    test "naming a dependency the step does not depend on is a validation error", %{ws: ws} do
      spec =
        audit_spec("audit_bad_ref", %{
          "allow_unverified_depends_on" => ["not_a_dependency"]
        })

      assert {:error, %{ok: false, error: error}} = Workflows.dry_run(spec, workspace: ws)
      assert error.kind == :invalid_args

      assert error.message =~
               "allow_unverified_depends_on must reference a declared dependency"

      assert error.details["id"] == "audit"
      assert error.details["allow_unverified_depends_on"] == ["not_a_dependency"]
      assert error.details["unknown"] == ["not_a_dependency"]
    end

    test "the opt-in is a first-class part of the step contract", %{ws: ws} do
      assert "allow_unverified_depends_on" in Workflows.workflow_step_keys()

      step_properties =
        Pixir.Tools.RunWorkflow.__tool__()
        |> get_in([:parameters, "properties", "steps", "items", "properties"])

      assert %{"type" => "array", "items" => %{"type" => "string"}, "description" => description} =
               step_properties["allow_unverified_depends_on"]

      assert description =~ "unverified"

      spec = audit_spec("audit_dry_run", %{"allow_unverified_depends_on" => ["partial_writer"]})

      assert {:ok, plan} = Workflows.dry_run(spec, workspace: ws)

      audit_plan = Enum.find(plan["would_run"], &(&1["id"] == "audit"))
      assert audit_plan["allow_unverified_depends_on"] == ["partial_writer"]

      writer_plan = Enum.find(plan["would_run"], &(&1["id"] == "partial_writer"))
      refute Map.has_key?(writer_plan, "allow_unverified_depends_on")
    end

    test "an engine-completed virtual_overlay audit records the unverified basis too", %{
      sid: sid,
      ws: ws
    } do
      spec = %{
        "id" => "audit_virtual",
        "steps" => [
          %{"id" => "partial_writer", "task" => "write", "agent" => "explorer"},
          %{
            "id" => "audit",
            "task" => "inspect the source",
            "workspace_mode" => "virtual_overlay",
            "read_set" => ["source.txt"],
            "virtual_commands" => ["cat source.txt"],
            "depends_on" => ["partial_writer"],
            "allow_unverified_depends_on" => ["partial_writer"]
          }
        ]
      }

      assert {:ok, result} = run_marker(sid, ws, spec)

      assert result["held_steps"] == []

      audit = Enum.find(result["steps"], &(&1["id"] == "audit"))
      assert audit["checkpoint_status"] == "checkpoint_ready"

      assert audit["checkpoint"]["verification"]["unverified_dependencies"] == ["partial_writer"]

      assert "ran_against_unverified_dependencies" in audit["checkpoint"]["known_limitations"]

      assert [%{"payload" => %{"unverified_dependencies" => ["partial_writer"]}}] =
               audit["checkpoint"]["typed_payloads"]
    end

    test "a run whose steps all reach checkpoint_ready still reports completed", %{
      sid: sid,
      ws: ws
    } do
      spec = %{
        "id" => "audit_all_ready",
        "steps" => [
          %{"id" => "writer", "task" => "write", "agent" => "explorer"},
          %{
            "id" => "audit",
            "task" => "audit",
            "agent" => "explorer",
            "depends_on" => ["writer"],
            "allow_unverified_depends_on" => ["writer"]
          }
        ]
      }

      assert {:ok, result} = run_marker(sid, ws, spec)

      assert result["ok"] == true
      assert result["status"] == "completed"
      assert result["summary"]["checkpoint_ready_steps"] == 2

      audit = Enum.find(result["steps"], &(&1["id"] == "audit"))
      refute Map.has_key?(audit["checkpoint"]["verification"], "unverified_dependencies")
      refute "ran_against_unverified_dependencies" in audit["checkpoint"]["known_limitations"]
    end
  end

  defp conflict_workflow do
    %{
      "id" => "conflict",
      "name" => "Conflict workflow",
      "max_concurrency" => 4,
      "steps" => [
        %{"id" => "inspect_a", "task" => "inspect A", "agent" => "explorer"},
        %{"id" => "inspect_b", "task" => "inspect B", "agent" => "explorer"},
        %{
          "id" => "write_a",
          "task" => "write A",
          "agent" => "worker",
          "write_set" => ["shared/result.txt"]
        },
        %{
          "id" => "write_b",
          "task" => "write B",
          "agent" => "worker",
          "write_set" => ["shared/result.txt"]
        },
        %{
          "id" => "summarize",
          "task" => "summarize",
          "agent" => "explorer",
          "depends_on" => ["inspect_a", "inspect_b", "write_a", "write_b"]
        }
      ]
    }
  end

  defp dependency_workflow do
    %{
      "id" => "deps",
      "name" => "Dependency workflow",
      "max_concurrency" => 2,
      "steps" => [
        %{"id" => "inspect_a", "task" => "inspect A", "agent" => "explorer"},
        %{"id" => "inspect_b", "task" => "inspect B", "agent" => "explorer"},
        %{
          "id" => "summarize",
          "task" => "summarize both",
          "agent" => "explorer",
          "depends_on" => ["inspect_a", "inspect_b"]
        }
      ]
    }
  end

  defp collect_prompts(count), do: collect_prompts(count, [])

  defp collect_prompts(0, acc), do: Enum.reverse(acc)

  defp collect_prompts(count, acc) do
    receive do
      {:workflow_prompt, prompt} -> collect_prompts(count - 1, [prompt | acc])
    after
      1_000 -> flunk("expected #{count} more workflow prompt(s)")
    end
  end

  defp collect_requests(count), do: collect_requests(count, [])

  defp collect_requests(0, acc), do: Enum.reverse(acc)

  defp collect_requests(count, acc) do
    receive do
      {:workflow_request, request} -> collect_requests(count - 1, [request | acc])
    after
      1_000 -> flunk("expected #{count} more workflow request(s)")
    end
  end

  defp workflow_events(history), do: Enum.filter(history, &(&1.type == :workflow_event))

  defp write_skill(dir, name, description) do
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: #{name}
    description: #{description}
    ---

    # #{description}
    """)

    dir
  end

  defp write_workflow_template(skill_dir, name, payload) do
    dir = Path.join(skill_dir, "workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.json"), Jason.encode!(payload, pretty: true))
  end
end
