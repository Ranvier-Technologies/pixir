defmodule Pixir.LandingManifestBudgetTest do
  use ExUnit.Case, async: false

  alias Pixir.{SessionSupervisor, Subagents}
  alias Pixir.Tools.{RunWorkflow, WaitAgent}

  defmodule Writer do
    def paths do
      for i <- 1..20,
          do:
            Path.join([
              String.duplicate("á", 80),
              String.duplicate("b", 160),
              String.duplicate("c", 160),
              "result-#{i}.txt"
            ])
    end

    def stream(%{history: history}, _opts) do
      if Enum.any?(history, &(&1.type == :tool_result)) do
        {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
      else
        calls =
          for {path, i} <- Enum.with_index(paths()),
              do: %{
                call_id: "write-#{i}",
                name: "write",
                args: %{"path" => path, "content" => "ok"}
              }

        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: calls,
           finish_reason: :tool_calls
         }}
      end
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-manifest-budget-" <> Base.encode16(:crypto.strong_rand_bytes(6))
      )

    File.mkdir_p!(ws)
    {:ok, sid, _} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      try do
        {:ok, children} = Subagents.list(sid, workspace: ws)

        for child <- children do
          Subagents.close(sid, child["id"], workspace: ws)

          if child["child_session_id"],
            do: SessionSupervisor.stop_session(child["child_session_id"])
        end
      after
        SessionSupervisor.stop_session(sid)
        File.rm_rf!(ws)
      end
    end)

    %{ws: ws, sid: sid}
  end

  test "wait_agent bounds only the appended manifest and retains structured paths", %{
    ws: ws,
    sid: sid
  } do
    {:ok, child} =
      Subagents.spawn_agent(
        sid,
        %{"task" => "write long paths", "workspace_mode" => "shared", "timeout_ms" => 10_000},
        workspace: ws,
        provider: Writer,
        permission_mode: :auto
      )

    assert {:ok, result} =
             WaitAgent.execute(%{"ids" => [child["id"]], "timeout_ms" => 15_000}, %{
               workspace: ws,
               session_id: sid
             })

    prefix =
      Subagents.summarize_wait_outcome(result["outcome"]) <>
        "\n\n" <> Subagents.reverification_directive()

    assert_bounded_manifest(result, prefix, ws)
  end

  test "run_workflow bounds only the appended manifest and retains structured paths", %{
    ws: ws,
    sid: sid
  } do
    assert {:ok, result} =
             RunWorkflow.execute(
               %{
                 "id" => "large-manifest",
                 "steps" => [
                   %{
                     "id" => "write",
                     "task" => "write long paths",
                     "agent" => "worker",
                     "workspace_mode" => "shared",
                     "timeout_ms" => 10_000
                   }
                 ]
               },
               %{workspace: ws, session_id: sid, provider: Writer}
             )

    assert result["workflow"]["status"] == "completed"

    prefix =
      "Workflow large-manifest completed: 1 step(s), 1 wave(s)." <>
        "\n\n" <> Subagents.reverification_directive()

    assert_bounded_manifest(result, prefix, ws)
  end

  defp assert_bounded_manifest(result, prefix, ws) do
    [entry] = result["landing_manifest"]
    [produced] = entry["produced"]
    assert Enum.map(produced["paths"], & &1["path"]) == Writer.paths()
    assert produced["next_action"]["paths"] == Writer.paths()
    for path <- Writer.paths(), do: assert(File.read!(Path.join(ws, path)) == "ok")
    assert String.starts_with?(result["output"], prefix <> "\n\n")

    block =
      binary_part(
        result["output"],
        byte_size(prefix) + 2,
        byte_size(result["output"]) - byte_size(prefix) - 2
      )

    assert byte_size(block) <= 16_000
    assert String.valid?(block)
    assert block =~ "[truncated"
    assert String.starts_with?(block, "Landing manifest:")
  end
end
