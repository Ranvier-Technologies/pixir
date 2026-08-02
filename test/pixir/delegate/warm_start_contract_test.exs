defmodule Pixir.Delegate.WarmStartContractTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Log, Workflows}
  alias Pixir.Delegate.{CLIContract, Runner}
  alias Pixir.Subagents.WarmStart

  defmodule EchoProvider do
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

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-warm-contract-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf!(ws) end)
    {:ok, ws: ws}
  end

  defp seed_log(ws, sid) do
    [
      Event.user_message(sid, "read lib/pixir/log.ex"),
      Event.assistant_message(sid, "log.ex is the append-only NDJSON writer")
    ]
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      {:ok, _} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)

    sid
  end

  defp dry_run(spec, ws) do
    CLIContract.run(["--spec", "-", "--dry-run", "--json"],
      workspace: ws,
      read_stdin: fn -> Jason.encode!(spec) end
    )
  end

  describe "spec validation" do
    test "accepts a per-task seed_session_id for the subagents strategy", %{ws: ws} do
      seed = seed_log(ws, "contract-seed-ok")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "summarize it", "seed_session_id" => seed}]
      }

      assert {:ok, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == true
    end

    test "accepts a per-step seed_session_id for the workflow strategy", %{ws: ws} do
      seed = seed_log(ws, "contract-seed-wf")

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [%{"id" => "one", "task" => "summarize", "seed_session_id" => seed}]
      }

      assert {:ok, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == true
    end

    # The runner resolves the spec's own `workspace` field first and validates every
    # seed against THAT root. A dry-run reading from the caller root instead would
    # reject a seed the real run accepts (#435).
    test "resolves the seed against the spec workspace, not the caller workspace", %{ws: ws} do
      nested = Path.join(ws, "nested")
      File.mkdir_p!(nested)
      seed = seed_log(nested, "contract-seed-nested")

      # the seed exists ONLY under the nested spec workspace
      refute File.exists?(Log.path(seed, workspace: ws))

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "workspace" => "nested",
        "tasks" => [%{"task" => "summarize", "seed_session_id" => seed}]
      }

      assert {:ok, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == true
    end

    test "rejects a seed naming a session that does not exist", %{ws: ws} do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "summarize", "seed_session_id" => "contract-seed-absent"}]
      }

      assert {:error, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == false
      assert payload["kind"] == "invalid_spec"
      details = payload["details"] || %{}
      assert details["next_actions"] != []
      assert details["seed_session_id"] == "contract-seed-absent"
      assert details["json_pointer"] == "/tasks/0/seed_session_id"
      assert payload["next_actions"] != []
    end

    test "rejects a non-string seed_session_id", %{ws: ws} do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "summarize", "seed_session_id" => 42}]
      }

      assert {:error, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == false
      assert payload["kind"] == "invalid_spec"
    end

    test "a spec with no seed reference is accepted unchanged", %{ws: ws} do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["plain task"]
      }

      assert {:ok, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == true
    end

    test "unknown task keys are still rejected", %{ws: ws} do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "summarize", "seed_session" => "typo"}]
      }

      assert {:error, %{payload: payload}} = dry_run(spec, ws)
      assert payload["ok"] == false
    end
  end

  describe "envelope" do
    test "the envelope schema revision is bumped additively", %{ws: ws} do
      spec = %{"contract_version" => 1, "strategy" => "subagents", "tasks" => ["plain task"]}

      assert {:ok, %{payload: payload}} = dry_run(spec, ws)
      assert payload["schema_version"] >= 8

      # existing keys consumers already read stay present
      assert Map.has_key?(payload, "ok")
      assert Map.has_key?(payload, "kind")
      assert Map.has_key?(payload, "strategy")
    end

    test "each child reports its warm-start lineage, cold children report absence", %{ws: ws} do
      seed = seed_log(ws, "contract-seed-envelope")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [
          %{"task" => "warm one", "seed_session_id" => seed},
          %{"task" => "cold one"}
        ]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn _parent, args, opts ->
        warm =
          case Keyword.get(opts, :seed_session_id) do
            nil ->
              %{"warm_started" => false, "seed_session_id" => nil}

            sid ->
              %{"warm_started" => true, "seed_session_id" => sid}
          end

        {:ok,
         %{
           "id" => "sub-#{:erlang.phash2(args["task"])}",
           "status" => "completed",
           "child_session_id" => "child-#{:erlang.phash2(args["task"])}",
           "task" => args["task"],
           "summary" => "done",
           "warm_start" => warm
         }}
      end

      wait_outcome = fn _parent, _ids, _horizon, _opts ->
        {:ok, %{"status" => "completed", "counts" => %{"completed" => 2}}}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      children = payload["children"]
      assert length(children) == 2

      warm = Enum.find(children, &(&1["task"] == "warm one"))
      cold = Enum.find(children, &(&1["task"] == "cold one"))

      assert warm["warm_start"]["warm_started"] == true
      assert warm["warm_start"]["seed_session_id"] == seed

      # cold children report the ABSENCE of a seed, not an omitted key
      assert Map.has_key?(cold, "warm_start")
      assert cold["warm_start"]["warm_started"] == false
      assert cold["warm_start"]["seed_session_id"] == nil
    end

    # Regression for #435: the subagents envelope builds warm_start via
    # child_result_base/1, but the WORKFLOW envelope is assembled by a separate
    # path (Workflows.complete_record/2 -> Runner.workflow_child_result/2) that
    # dropped the key entirely. This runs the REAL machinery -- no fabricated
    # warm_start map -- so both projection hops are exercised for real: the
    # lineage asserted here is the one the runtime actually derived.
    test "a workflow child reports its warm-start lineage on a real run", %{ws: ws} do
      seed = seed_log(ws, "contract-seed-wf-envelope")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "steps" => [
          %{"id" => "warm", "task" => "summarize", "seed_session_id" => seed},
          %{"id" => "cold", "task" => "other"}
        ]
      }

      spec_meta = %{"strategy" => "workflow", "planned_child_count" => 2}

      workflow_runner = fn parent, workflow_spec, opts ->
        result =
          Workflows.run(
            parent,
            workflow_spec,
            opts
            |> Keyword.put(:provider, EchoProvider)
            |> Keyword.put(:poll_ms, 10)
            |> Keyword.put(:timeout_ms, 10_000)
          )

        with {:ok, %{"steps" => steps}} <- result do
          send(test_pid, {:workflow_steps, steps})
        end

        result
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      children = payload["children"]
      assert length(children) == 2

      warm = Enum.find(children, &(&1["step_id"] == "warm"))
      cold = Enum.find(children, &(&1["step_id"] == "cold"))

      assert Map.has_key?(warm, "warm_start"),
             "a warm workflow child must not omit warm_start from the envelope"

      assert warm["warm_start"]["warm_started"] == true
      assert warm["warm_start"]["seed_session_id"] == seed
      # derived by the runtime from the seeded Log, not supplied by the test
      assert warm["warm_start"]["fork_root_session_id"] == seed
      assert warm["warm_start"]["replay_event_count"] == 2
      assert warm["warm_start"]["boundary_marker_kind"] == WarmStart.boundary_marker_kind()

      # a cold workflow child reports the ABSENCE of a seed, not an omitted key
      assert Map.has_key?(cold, "warm_start"),
             "a cold workflow child must report absence rather than omitting the key"

      assert cold["warm_start"]["warm_started"] == false
      assert cold["warm_start"]["seed_session_id"] == nil

      # the step projection itself must carry the key, not just the envelope:
      # Workflows.complete_record/2 was the first of the two dropped hops.
      assert_received {:workflow_steps, steps}
      warm_step = Enum.find(steps, &(&1["step_id"] == "warm"))
      cold_step = Enum.find(steps, &(&1["step_id"] == "cold"))
      assert warm_step["warm_start"]["warm_started"] == true
      assert warm_step["warm_start"]["seed_session_id"] == seed
      assert cold_step["warm_start"]["warm_started"] == false
    end
  end

  describe "runtime plumbing" do
    test "the runner passes the per-task seed reference into the spawn opts", %{ws: ws} do
      seed = seed_log(ws, "contract-seed-plumbing")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "warm", "seed_session_id" => seed}, %{"task" => "cold"}]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn _parent, args, opts ->
        send(test_pid, {:spawned, args["task"], Keyword.get(opts, :seed_session_id)})

        # a seed reference must NEVER travel through args: it is runtime-owned
        refute Map.has_key?(args, "seed_session_id")

        {:ok,
         %{
           "id" => "sub-#{:erlang.phash2(args["task"])}",
           "status" => "completed",
           "child_session_id" => "child-#{:erlang.phash2(args["task"])}",
           "task" => args["task"]
         }}
      end

      wait_outcome = fn _parent, _ids, _horizon, _opts ->
        {:ok, %{"status" => "completed", "counts" => %{"completed" => 2}}}
      end

      assert {:ok, _payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert_receive {:spawned, "warm", ^seed}
      assert_receive {:spawned, "cold", nil}
    end
  end
end
