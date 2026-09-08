defmodule Pixir.Delegate.TransportForwardingTest do
  use ExUnit.Case, async: false
  alias Pixir.Delegate.Runner

  defmodule CaptureProvider do
    def stream(%{history: history}, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:transport_seen, opts[:provider_transport], opts[:unrelated_option]}
      )

      if opts[:virtual_arm] and not Enum.any?(history, &(&1.type == :tool_result)) do
        {:ok,
         %{
           text: "",
           reasoning: "",
           finish_reason: :tool_calls,
           function_calls: [
             %{
               call_id: "read_fixture",
               name: "run_virtual_commands",
               args: %{"commands" => ["cat fixture.txt"]}
             }
           ]
         }}
      else
        {:ok,
         %{
           text: "checkpoint_status: checkpoint_ready",
           reasoning: "",
           function_calls: [],
           finish_reason: :stop
         }}
      end
    end
  end

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-transport-forwarding-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "fixture.txt"), "fixture\n")

    on_exit(fn ->
      parents = Path.wildcard(Path.join(ws, ".pixir/sessions/*.ndjson"))

      for file <- parents do
        sid = Path.basename(file, ".ndjson")
        {:ok, children} = Pixir.Subagents.list(sid, workspace: ws)

        for child <- children,
            child["status"] != "closed",
            do: Pixir.Subagents.close(sid, child["id"], workspace: ws)
      end

      for file <- Path.wildcard(Path.join(ws, "**/.pixir/sessions/*.ndjson"), match_dot: true),
          do: Pixir.SessionSupervisor.stop_session(Path.basename(file, ".ndjson"))

      File.rm_rf!(ws)
    end)

    %{ws: ws}
  end

  for {strategy, mode} <- [
        {"subagents", "shared"},
        {"subagents", "isolated"},
        {"subagents", "virtual_overlay"},
        {"workflow", "shared"}
      ],
      location <- [:top, :nested] do
    @strategy strategy
    @mode mode
    @location location
    test "#{strategy}/#{mode} forwards #{location} transport to the actual child Provider", %{
      ws: ws
    } do
      spec = spec(@strategy, @mode)

      spec =
        if @location == :top,
          do: Map.put(spec, "transport", "http_sse"),
          else:
            Map.update(
              spec,
              "subagents",
              %{"transport" => "http_sse"},
              &Map.put(&1, "transport", "http_sse")
            )

      assert {:ok, _} = run(spec, ws, @mode, provider_transport: :websocket)
      assert_receive {:transport_seen, "http_sse", :preserved}
      refute_received {:transport_seen, :websocket, _}
    end
  end

  test "omission preserves inherited transport and absence; nested spec wins over top", %{ws: ws} do
    base = spec("subagents", "shared")
    assert {:ok, _} = run(base, ws, "shared", provider_transport: :websocket)
    assert_receive {:transport_seen, :websocket, :preserved}
    assert {:ok, _} = run(base, ws, "shared", [])
    assert_receive {:transport_seen, nil, :preserved}

    configured =
      base
      |> Map.put("transport", "websocket")
      |> Map.update!("subagents", &Map.put(&1, "transport", "http_sse"))

    assert {:ok, _} = run(configured, ws, "shared", [])
    assert_receive {:transport_seen, "http_sse", :preserved}
  end

  defp spec(strategy, mode) do
    base = %{"contract_version" => 1, "strategy" => strategy, "mode" => "read_only"}

    if strategy == "workflow" do
      Map.put(base, "steps", [
        %{
          "id" => "inspect",
          "task" => "inspect transport",
          "agent" => "explorer",
          "workspace_mode" => "shared"
        }
      ])
    else
      subagents = %{"workspace_mode" => mode}

      subagents =
        if mode == "virtual_overlay",
          do: Map.put(subagents, "read_set", ["fixture.txt"]),
          else: subagents

      Map.merge(base, %{"task" => "inspect transport", "subagents" => subagents})
    end
  end

  defp run(spec, ws, mode, provider_opts) do
    Runner.run(
      %{workspace: ws},
      spec,
      %{"strategy" => spec["strategy"], "planned_child_count" => 1},
      provider: CaptureProvider,
      provider_opts:
        [test_pid: self(), unrelated_option: :preserved, virtual_arm: mode == "virtual_overlay"] ++
          provider_opts
    )
  end
end
