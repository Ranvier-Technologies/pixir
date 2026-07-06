defmodule Pixir.Subagents.ManagerRetryTest do
  use ExUnit.Case, async: false

  alias Pixir.{Log, SessionSupervisor, Subagents}

  defmodule ScriptedProvider do
    @script __MODULE__.Script

    def start_script(results) do
      case Process.whereis(@script) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end

      Agent.start_link(fn -> results end, name: @script)
    end

    def stop_script do
      if pid = Process.whereis(@script) do
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end
    end

    def stream(_request, _opts) do
      case Agent.get_and_update(@script, fn
             [result | rest] -> {result, rest}
             [] -> {:ok, []}
           end) do
        :ok ->
          {:ok,
           %{text: "retry succeeded", reasoning: "", function_calls: [], finish_reason: :stop}}

        :websocket_read_failed ->
          provider_error(:websocket_read_failed)

        :server_error ->
          provider_error(:server_error)

        :provider_http_server_error ->
          provider_error(:provider_http_error, %{
            type: "server_error",
            code: "server_error",
            status: 200
          })

        :provider_http_invalid_request ->
          provider_error(:provider_http_error, %{
            type: "invalid_request",
            code: "invalid_request",
            status: 400
          })
      end
    end

    defp provider_error(kind, details \\ %{reason: :scripted}) do
      {:error,
       %{
         ok: false,
         error: %{
           kind: kind,
           message: "scripted provider failure",
           details: details
         }
       }}
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-subagent-retry-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "source.txt"), "parent source")
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      ScriptedProvider.stop_script()

      try do
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf(ws)
    end)

    %{ws: ws, sid: sid}
  end

  test "websocket provider failures retry once and preserve failed attempt history", %{
    sid: sid,
    ws: ws
  } do
    {:ok, _} = ScriptedProvider.start_script([:websocket_read_failed, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "retry websocket once",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :read_only
      )

    failed_child_session_id = agent["child_session_id"]

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert completed["status"] == "completed"
    assert completed["child_session_id"] != failed_child_session_id
    assert completed["retry_attempts"] == 1
    assert completed["retry_max_attempts"] == 1
    assert completed["current_attempt_index"] == 1

    assert [
             %{
               "failed_child_session_id" => ^failed_child_session_id,
               "error_kind" => public_error_kind
             }
           ] = completed["retry_history"]

    assert public_error_kind in [:websocket_read_failed, "websocket_read_failed"]

    runtime_agent = runtime_agent(agent["id"])

    assert [%{"failed_child_session_id" => ^failed_child_session_id, "error_kind" => kind}] =
             runtime_agent.retry_history

    assert kind in [:websocket_read_failed, "websocket_read_failed"]

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert Enum.any?(
             history,
             &(&1.type == :subagent_event and &1.data["subagent_id"] == agent["id"] and
                 &1.data["event"] == "retrying")
           )
  end

  test "non-websocket provider errors are not retried", %{sid: sid, ws: ws} do
    {:ok, _} = ScriptedProvider.start_script([:server_error, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "do not retry server error",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :read_only
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert failed["status"] == "failed"
    assert runtime_agent(agent["id"]).retry_history == []
  end

  test "websocket retries are bounded by retry_attempts", %{sid: sid, ws: ws} do
    {:ok, _} =
      ScriptedProvider.start_script([:websocket_read_failed, :websocket_read_failed, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "retry only once",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :read_only
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert failed["status"] == "failed"
    assert length(runtime_agent(agent["id"]).retry_history) == 1
  end

  test "write-capable children are not retried", %{sid: sid, ws: ws} do
    {:ok, _} = ScriptedProvider.start_script([:websocket_read_failed, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "write capable no retry",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :auto,
        write_policy: %{"allow_writes" => ["result.txt"]}
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert failed["status"] == "failed"
    assert runtime_agent(agent["id"]).retry_history == []
  end

  defp runtime_agent(id) do
    Pixir.Subagents.Manager
    |> :sys.get_state()
    |> find_runtime_agent(id)
  end

  defp find_runtime_agent(%{id: agent_id} = agent, id) when agent_id == id, do: agent

  defp find_runtime_agent(map, id) when is_map(map) do
    map
    |> Map.values()
    |> Enum.find_value(&find_runtime_agent(&1, id))
  end

  defp find_runtime_agent(list, id) when is_list(list) do
    Enum.find_value(list, &find_runtime_agent(&1, id))
  end

  defp find_runtime_agent(tuple, id) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> find_runtime_agent(id)
  end

  defp find_runtime_agent(_other, _id), do: nil

  test "provider-declared retryable server errors retry like websocket drops", %{
    sid: sid,
    ws: ws
  } do
    {:ok, _} = ScriptedProvider.start_script([:provider_http_server_error, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "retry server_error once",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :read_only
      )

    assert {:ok, [completed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert completed["status"] == "completed"
    assert completed["retry_attempts"] == 1
    assert [entry] = completed["retry_history"]
    assert entry["error_kind"] == "provider_http_error"
  end

  test "provider_http_error with a non-retryable type is not retried", %{
    sid: sid,
    ws: ws
  } do
    {:ok, _} = ScriptedProvider.start_script([:provider_http_invalid_request, :ok])

    {:ok, agent} =
      Subagents.spawn_agent(
        sid,
        %{
          "task" => "no retry for invalid_request",
          "agent" => "worker",
          "retry_attempts" => 1,
          "retry_jitter_ms" => 0,
          "timeout_ms" => 5_000
        },
        workspace: ws,
        provider: ScriptedProvider,
        permission_mode: :read_only
      )

    assert {:ok, [failed]} = Subagents.wait(sid, [agent["id"]], 5_000, workspace: ws)
    assert failed["status"] == "failed"
    refute Map.has_key?(failed, "retry_history")
    assert runtime_agent(agent["id"]).retry_history == []
  end
end
