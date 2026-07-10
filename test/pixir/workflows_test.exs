defmodule Pixir.WorkflowsTest do
  use ExUnit.Case, async: false

  alias Pixir.{Log, SessionSupervisor, Subagents, Workflows}
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

    # Each negative spec must fail for ITS OWN reason: expected
    # {location, message-fragment} per case, in order. Locations are
    # zero-based JSON pointers into the spec.
    expectations = [
      {"/steps/0/apply_from", "must reference a previous virtual_overlay step"},
      {"/steps/1/apply_from", "must use workspace_mode virtual_overlay"},
      {"/steps/1/apply_from", "must be listed in depends_on"},
      {"/steps/1/apply_from", "requires write_set"},
      {"/steps/1/apply_from", "do not spawn subagents"}
    ]

    for {spec, {location, fragment}} <- Enum.zip(specs, expectations) do
      assert {:error, %{error: %{kind: :invalid_spec, message: message, details: details}}} =
               Workflows.dry_run(spec, workspace: ws, write_policy: policy)

      assert details["location"] == location,
             "expected #{location} for fragment #{fragment}, got #{details["location"]}"

      assert message =~ fragment

      assert {:error, %{error: %{kind: :invalid_spec, message: ^message}}} =
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
    assert [_producer, %{"virtual_diff_apply" => %{"status" => "applied"}}] = result["steps"]
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
    assert details["allowed"] == ~w(low medium high xhigh)
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
