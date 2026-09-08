defmodule Pixir.DelegateTest do
  use ExUnit.Case, async: true

  alias Pixir.{Delegate.Runner, Subagents}

  test "delegate summary appends the directive for completed children" do
    summary = "delegate completed."

    assert Runner.presentation_summary_for_test(summary, [%{"status" => "completed"}]) ==
             summary <> "\n\n" <> Subagents.reverification_directive()
  end

  test "delegate summary remains byte-identical without integrable children" do
    summary = "delegate failed; inspect child sessions for details."

    assert Runner.presentation_summary_for_test(summary, [%{"status" => "failed"}]) == summary
  end

  test "execute-level payload appends only its summary when a child is integrable", %{test: test} do
    workspace = Path.join(System.tmp_dir!(), "pixir-delegate-test-#{test}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    request = %{
      workspace: workspace,
      timeout_ms: 120_000,
      delegate_timeout_ms: 120_000,
      child_timeout_ms: 120_000,
      wait_horizon_ms: 120_000
    }

    spec = %{
      "mode" => "read_only",
      "tasks" => ["pin result payload"],
      "subagents" => %{"max_threads" => 1}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}
    child_summary = "child completed bytes"

    spawn_agent = fn _parent_session_id, _args, _opts ->
      {:ok,
       %{
         "id" => "child-1",
         "child_session_id" => "child-session-1",
         "agent" => "explorer",
         "status" => "running",
         "summary" => nil,
         "task" => "pin result payload",
         "workspace_mode" => "shared",
         "workspace" => workspace,
         "child_log_path" => Path.join(workspace, "child-session-1.ndjson")
       }}
    end

    wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
      {:ok,
       %{
         "status" => "completed",
         "counts" => %{"completed" => 1},
         "subagents" => [
           %{
             "id" => "child-1",
             "child_session_id" => "child-session-1",
             "agent" => "explorer",
             "status" => "completed",
             "summary" => child_summary,
             "task" => "pin result payload",
             "workspace_mode" => "shared",
             "workspace" => workspace,
             "child_log_path" => Path.join(workspace, "child-session-1.ndjson")
           }
         ]
       }}
    end

    assert {:ok, payload} =
             Runner.run(request, spec, spec_meta,
               spawn_agent: spawn_agent,
               wait_outcome: wait_outcome
             )

    assert payload["summary"] ==
             "delegate completed.\n\n" <> Subagents.reverification_directive()

    refute Map.has_key?(payload, "landing_manifest")
    assert [%{"summary" => ^child_summary}] = payload["children"]
    refute hd(payload["children"])["summary"] =~ Subagents.reverification_directive()
  end
end
