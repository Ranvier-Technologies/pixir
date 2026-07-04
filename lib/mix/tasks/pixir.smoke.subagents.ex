defmodule Mix.Tasks.Pixir.Smoke.Subagents do
  @shortdoc "No-network smoke/stress for ADR 0011 Subagents"

  @moduledoc """
  Verifies Pixir Subagents end-to-end without hitting the network:

    * spawns 50 supervised child Sessions with a fake provider;
    * verifies result collection and compact parent aggregation;
    * verifies isolated child workspaces and no parent write interference;
    * verifies lifecycle NDJSON evidence and reconstruction from Log;
    * verifies max_threads queueing, timeouts, close/cancel, send_input, and max_depth.

  Usage:

      mix pixir.smoke.subagents
  """

  use Mix.Task

  alias Pixir.{Auth, Log, Provider, SessionSupervisor, Subagents}

  @impl Mix.Task
  def run(_args) do
    scratch = scratch_dir()
    workspace = Path.join(scratch, "workspace")

    try do
      Mix.Task.run("app.start")
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "source.txt"), "parent source")

      with {:ok, sid, _pid} <- SessionSupervisor.start_session(workspace: workspace, role: :build),
           :ok <- prove_many_subagents(sid, workspace),
           :ok <- prove_provider_aggregation(sid, workspace),
           :ok <- prove_send_input(sid, workspace),
           :ok <- prove_queue_timeout_and_close(sid, workspace),
           :ok <- prove_depth_guard(sid, workspace) do
        Mix.shell().info("""

        Subagents smoke passed.
          workspace: #{workspace}
          session:   #{sid}
          stress:    50 child sessions completed with isolated writes
        """)
      else
        {:error, stage, reason} -> fail(stage, reason)
        other -> fail("unexpected", other)
      end
    after
      File.rm_rf!(scratch)
    end
  end

  defmodule WritingProvider do
    def stream(%{history: history}, opts) do
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
      users = Enum.filter(history, &(&1.type == :user_message))
      results = Enum.filter(history, &(&1.type == :tool_result))
      prompt = users |> List.last() |> then(&((&1 && &1.data["text"]) || ""))

      if length(results) < length(users) do
        {:ok,
         %{
           text: "",
           reasoning: "",
           reasoning_items: [],
           function_calls: [
             %{
               call_id: "write_#{length(users)}",
               name: "write",
               args: %{"path" => "result.txt", "content" => prompt}
             }
           ],
           finish_reason: :tool_calls
         }}
      else
        on_delta.({:text_delta, "done"})

        {:ok,
         %{
           text: "wrote isolated result for #{prompt}",
           reasoning: "",
           function_calls: [],
           finish_reason: :stop
         }}
      end
    end
  end

  defmodule BlockingProvider do
    def stream(_request, _opts) do
      Process.sleep(10_000)
      {:ok, %{text: "late", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defp prove_many_subagents(sid, workspace) do
    agents =
      for i <- 1..50 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{
              "task" => "task-#{i}",
              "agent" => "worker",
              "max_threads" => 8,
              "timeout_ms" => 5_000
            },
            workspace: workspace,
            provider: WritingProvider,
            permission_mode: :auto
          )

        agent
      end

    with {:ok, completed} <- Subagents.wait(sid, Enum.map(agents, & &1["id"]), 10_000),
         true <-
           Enum.all?(completed, &(&1["status"] == "completed")) ||
             {:error, "some children did not complete"},
         true <-
           not File.exists?(Path.join(workspace, "result.txt")) ||
             {:error, "parent workspace was written"} do
      missing =
        Enum.reject(completed, fn agent ->
          case File.read(Path.join(agent["workspace"], "result.txt")) do
            {:ok, "task-" <> _rest} -> true
            _ -> false
          end
        end)

      if missing == [] do
        assert_lifecycle_evidence(sid, workspace, 50)
      else
        {:error, "stress",
         "missing child result files: #{inspect(Enum.map(missing, & &1["id"]))}"}
      end
    else
      {:error, reason} -> {:error, "stress", reason}
      other -> {:error, "stress", other}
    end
  end

  defp assert_lifecycle_evidence(sid, workspace, expected_finished) do
    with {:ok, history} <- Log.fold(sid, workspace: workspace) do
      finished =
        Enum.count(history, &(&1.type == :subagent_event and &1.data["event"] == "finished"))

      reconstructed = Subagents.reconstruct(history)
      summary = reconstructed |> Map.values() |> Subagents.summarize()

      cond do
        finished < expected_finished ->
          {:error, "log", "expected #{expected_finished} finished events, got #{finished}"}

        map_size(reconstructed) < expected_finished ->
          {:error, "log", "reconstructed only #{map_size(reconstructed)} subagents"}

        not String.contains?(summary, "completed") ->
          {:error, "log", "summary aggregation missing completed statuses"}

        true ->
          Mix.shell().info("Step 1/5 - stress, isolation, NDJSON, reconstruction passed.")
          :ok
      end
    end
  end

  defp prove_provider_aggregation(sid, workspace) do
    name = :"subagents_smoke_auth_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "pixir-subagents-smoke-auth-#{name}.json")

    try do
      with {:ok, history} <- Log.fold(sid, workspace: workspace),
           {:ok, _pid} <-
             Auth.start_link(
               name: name,
               store_path: path,
               env_api_key: "sk-smoke",
               oauth: NoOAuth
             ),
           {:ok, _} <-
             Provider.stream(%{history: history},
               auth: name,
               transport: capture_transport(self())
             ) do
        receive do
          {:provider_body, body} ->
            text =
              body["input"]
              |> Enum.flat_map(&Map.get(&1, "content", []))
              |> Enum.map_join("\n", &Map.get(&1, "text", ""))

            if text =~ "Subagent" and text =~ "completed" and
                 not String.contains?(text, "write_") do
              Mix.shell().info("Step 2/5 - parent provider aggregation passed.")
              :ok
            else
              {:error, "provider aggregation", "terminal summaries missing from replay"}
            end
        after
          1_000 -> {:error, "provider aggregation", "provider body was not captured"}
        end
      else
        other -> {:error, "provider aggregation", other}
      end
    after
      File.rm_rf!(path)
    end
  end

  defp capture_transport(test_pid) do
    fn request, acc, feed ->
      send(test_pid, {:provider_body, Jason.decode!(request.body)})
      acc = feed.({:status, 200}, acc)
      {:ok, feed.({:data, sse(%{type: "response.completed"})}, acc)}
    end
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp prove_send_input(sid, workspace) do
    with {:ok, agent} <-
           Subagents.spawn_agent(
             sid,
             %{"task" => "first", "timeout_ms" => 5_000},
             workspace: workspace,
             provider: WritingProvider,
             permission_mode: :auto
           ),
         {:ok, [_done]} <- Subagents.wait(sid, [agent["id"]], 5_000),
         {:ok, running} <- Subagents.send_input(sid, agent["id"], "second"),
         true <- running["status"] == "running" || {:error, "send_input did not restart"},
         {:ok, [completed]} <- Subagents.wait(sid, [agent["id"]], 5_000),
         {:ok, "second"} <- File.read(Path.join(completed["workspace"], "result.txt")) do
      Mix.shell().info("Step 3/5 - send_input restart passed.")
      :ok
    else
      other -> {:error, "send_input", other}
    end
  end

  defp prove_queue_timeout_and_close(sid, workspace) do
    ids =
      for i <- 1..3 do
        {:ok, agent} =
          Subagents.spawn_agent(
            sid,
            %{"task" => "block-#{i}", "max_threads" => 1, "timeout_ms" => 300},
            workspace: workspace,
            provider: BlockingProvider,
            permission_mode: :auto
          )

        agent["id"]
      end

    with {:ok, listed} <- Subagents.list(sid),
         true <- Enum.any?(listed, &(&1["status"] == "queued")) || {:error, "queue absent"},
         {:ok, waited} <- Subagents.wait(sid, ids, 3_000),
         true <- Enum.any?(waited, &(&1["status"] == "timed_out")) || {:error, "timeout absent"},
         {:ok, agent} <-
           Subagents.spawn_agent(
             sid,
             %{"task" => "close-me", "timeout_ms" => 5_000},
             workspace: workspace,
             provider: BlockingProvider,
             permission_mode: :auto
           ),
         {:ok, closed} <- Subagents.close(sid, agent["id"]),
         true <- Subagents.terminal?(closed["status"]) || {:error, "close did not terminalize"} do
      Mix.shell().info("Step 4/5 - queue, timeout, and close passed.")
      :ok
    else
      other -> {:error, "queue/timeout/close", other}
    end
  end

  defp prove_depth_guard(sid, workspace) do
    case Subagents.spawn_agent(
           sid,
           %{"task" => "too deep", "max_depth" => 1},
           workspace: workspace,
           provider: WritingProvider,
           depth: 1
         ) do
      {:error, %{error: %{kind: :permission_denied}}} ->
        Mix.shell().info("Step 5/5 - max_depth guard passed.")
        :ok

      other ->
        {:error, "depth", other}
    end
  end

  defp scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-subagents-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      )

    File.mkdir_p!(dir)
    dir
  end

  defp fail(stage, reason) do
    Mix.shell().error("subagents smoke failed at #{stage}: #{inspect(reason)}")
    exit({:shutdown, 1})
  end
end
