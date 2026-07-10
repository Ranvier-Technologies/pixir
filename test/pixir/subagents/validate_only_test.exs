defmodule Pixir.Subagents.ValidateOnlyTest do
  use ExUnit.Case, async: false

  alias Pixir.{Log, Permissions, SessionSupervisor, Subagents}
  alias Pixir.Subagents.Manager
  alias Pixir.Tools.{Executor, SpawnAgent}

  defmodule DoneProvider do
    def stream(_request, _opts) do
      {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-validate-spawn-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)

    {:ok, session_id, session_pid} =
      SessionSupervisor.start_session(workspace: workspace, role: :build)

    on_exit(fn ->
      try do
        if Process.alive?(session_pid) do
          DynamicSupervisor.terminate_child(SessionSupervisor, session_pid)
        end
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf!(workspace)
    end)

    %{session_id: session_id, workspace: workspace}
  end

  test "valid rehearsal returns effective defaults through an allowlisted plan", context do
    assert {:ok, %{"plan" => plan}} =
             run_spawn(context, %{"task" => "inspect", "validate_only" => true})

    defaults = Subagents.default_limits()

    assert plan["action"] == "spawn_agent"
    assert plan["agent"] == "default"
    assert plan["task"] == "inspect"
    assert plan["depth"] == 1
    assert plan["max_depth"] == defaults.max_depth
    assert plan["timeout_ms"] == defaults.timeout_ms
    assert plan["max_threads"] == defaults.max_threads
    assert plan["workspace_mode"] == "isolated"
    assert plan["workspace_fidelity"] == "bounded_physical_snapshot"
    assert plan["permission_mode"] == "auto"

    forbidden = ~w(id child_session_id log_path parent_log_path child_log_path deadline_at
                   workspace workspace_snapshot status provider provider_opts model
                   reasoning_effort web_search attachments index)

    refute Enum.any?(recursive_keys(plan), &(&1 in forbidden))
  end

  test "rehearsal changes no Manager, child, workspace, or lifecycle state", context do
    assert {:ok, before_agents} = Subagents.list(context.session_id, workspace: context.workspace)
    assert {:ok, before_history} = Log.fold(context.session_id, workspace: context.workspace)
    before_files = Path.wildcard(Path.join(context.workspace, ".pixir/subagents/**/*"))

    assert {:ok, %{"plan" => _plan}} =
             run_spawn(context, %{"task" => "inspect", "validate_only" => true})

    assert {:ok, after_agents} = Subagents.list(context.session_id, workspace: context.workspace)
    assert before_agents == after_agents
    assert Path.wildcard(Path.join(context.workspace, ".pixir/subagents/**/*")) == before_files

    assert {:ok, after_history} = Log.fold(context.session_id, workspace: context.workspace)
    new_events = Enum.drop(after_history, length(before_history))

    assert Enum.map(new_events, & &1.type) == [:tool_call, :tool_result]
    refute Enum.any?(new_events, &(&1.type == :subagent_event))
  end

  test "validation and real spawn return identical structured normalization errors", context do
    cases = [
      {%{"task" => "x", "agent" => "missing-agent"}, []},
      {%{"task" => "x", "timeout_ms" => 0}, []},
      {%{"task" => "x", "max_threads" => 0}, []},
      {%{"task" => "x", "max_depth" => -1}, []},
      {%{"task" => "x", "workspace_mode" => "unknown"}, []},
      {%{"task" => "x", "max_depth" => 1}, [depth: 1]}
    ]

    for {args, extra_opts} <- cases do
      opts = Keyword.merge(manager_opts(context), extra_opts)

      assert {:error, %{error: validation_error}} =
               Manager.validate_spawn(context.session_id, args, opts)

      assert {:error, %{error: spawn_error}} =
               Subagents.spawn_agent(context.session_id, args, opts)

      assert validation_error.kind == spawn_error.kind
      assert validation_error.details == spawn_error.details
    end
  end

  test "read_only and ask allow exact true while absent and false remain mutating", context do
    for mode <- [:read_only, :ask] do
      permission = %{mode: mode}

      assert {:ok, %{"plan" => _plan}} =
               run_spawn(
                 Map.put(context, :permission, permission),
                 %{"task" => "inspect", "validate_only" => true}
               )
    end

    assert Permissions.mutating?("spawn_agent", %{"validate_only" => true}) == false
    assert Permissions.mutating?("spawn_agent", %{}) == true
    assert Permissions.mutating?("spawn_agent", %{"validate_only" => false}) == true

    assert {:error, %{error: %{kind: :permission_denied}}} =
             run_spawn(
               Map.put(context, :permission, %{mode: :read_only}),
               %{"task" => "spawn"}
             )

    assert {:error, %{error: %{kind: :permission_denied}}} =
             run_spawn(
               Map.put(context, :permission, %{mode: :read_only}),
               %{"task" => "spawn", "validate_only" => false}
             )
  end

  test "virtual-overlay children may rehearse but may not really spawn", context do
    virtual_context = Map.put(context, :virtual_overlay, %{"read_set" => []})

    assert {:ok, %{"plan" => _plan}} =
             run_spawn(virtual_context, %{"task" => "inspect", "validate_only" => true})

    assert {:error, %{error: %{kind: :permission_denied}}} =
             run_spawn(virtual_context, %{"task" => "spawn"})
  end

  test "malformed validate_only values are invalid_args and never spawn", context do
    for value <- ["true", 1, nil] do
      assert {:error, %{error: %{kind: :invalid_args}}} =
               run_spawn(context, %{"task" => "inspect", "validate_only" => value})
    end

    assert {:ok, []} = Subagents.list(context.session_id, workspace: context.workspace)
  end

  test "model-authored runtime fields are stripped while trusted posture wins", context do
    args = %{
      "task" => "inspect",
      "validate_only" => true,
      "id" => "forged",
      "index" => 99,
      "attachments" => [%{"resource_id" => "forged"}],
      "model" => "forged-model",
      "reasoning_effort" => "xhigh",
      "web_search" => true
    }

    assert {:ok, %{"plan" => plan}} =
             run_spawn(Map.put(context, :permission, %{mode: :read_only}), args)

    assert plan["permission_mode"] == "read_only"

    refute Enum.any?(
             recursive_keys(plan),
             &(&1 in ~w(id index attachments model reasoning_effort web_search))
           )
  end

  test "Turn-level dry_run returns the same normalized plan as validate_only", context do
    assert {:ok, %{"plan" => rehearsal}} =
             run_spawn(context, %{"task" => "inspect", "validate_only" => true})

    assert {:ok, %{"plan" => dry_run}} =
             context
             |> Map.put(:dry_run, true)
             |> run_spawn(%{"task" => "inspect"})

    assert dry_run == rehearsal
  end

  test "validate_only false still creates exactly one child and lifecycle evidence", context do
    spawn_context = Map.put(context, :provider, DoneProvider)

    assert {:ok, %{"subagent" => agent}} =
             run_spawn(spawn_context, %{"task" => "finish", "validate_only" => false})

    assert {:ok, [listed]} = Subagents.list(context.session_id, workspace: context.workspace)
    assert listed["id"] == agent["id"]

    assert {:ok, [_finished]} =
             Subagents.wait(context.session_id, [agent["id"]], 5_000,
               workspace: context.workspace
             )

    assert {:ok, history} = Log.fold(context.session_id, workspace: context.workspace)

    assert Enum.any?(history, fn event ->
             event.type == :subagent_event and event.data["subagent_id"] == agent["id"]
           end)
  end

  test "tool contract advertises validate_only as an optional provider-compatible boolean" do
    schema = SpawnAgent.__tool__().parameters

    assert schema["properties"]["validate_only"] == %{
             "type" => "boolean",
             "description" =>
               "When exactly true, validate and normalize this spawn without creating a Subagent."
           }

    refute "validate_only" in schema["required"]
    assert {:ok, _json} = Jason.encode(schema)
  end

  test "plan explicitly confesses all runtime limitations", context do
    assert {:ok, %{"plan" => %{"limitations" => limitations}}} =
             run_spawn(context, %{"task" => "inspect", "validate_only" => true})

    assert limitations == [
             "Validation does not prove workspace snapshot capacity.",
             "Validation does not prove filesystem writeability.",
             "Validation does not prove provider authentication.",
             "Validation does not prove network reachability.",
             "Validation does not prove future queue position."
           ]
  end

  defp run_spawn(context, args) do
    context =
      context
      |> Map.put_new(:permission, %{mode: :auto})
      |> Map.put_new(:call_id, "spawn-" <> Integer.to_string(System.unique_integer([:positive])))

    Executor.run(
      %{
        call_id: context.call_id,
        name: "spawn_agent",
        args: args
      },
      context
    )
  end

  defp manager_opts(context) do
    [
      workspace: context.workspace,
      provider: DoneProvider,
      permission_mode: :auto,
      depth: 0
    ]
  end

  defp recursive_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [to_string(key) | recursive_keys(value)] end)
  end

  defp recursive_keys(values) when is_list(values), do: Enum.flat_map(values, &recursive_keys/1)
  defp recursive_keys(_value), do: []
end
