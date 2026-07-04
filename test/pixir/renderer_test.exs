defmodule Pixir.RendererTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Pixir.{Event, Events, Renderer, Session, SessionSupervisor, Turn}

  defmodule StubProvider do
    def stream(_request, opts) do
      agent = Keyword.fetch!(opts, :agent)
      on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
      result = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)

      case result do
        {:ok, %{text: text}} when text != "" -> on_delta.({:text_delta, text})
        _ -> :ok
      end

      result
    end
  end

  describe "render/1 channel mapping" do
    test "text deltas and the assistant newline go to stdout" do
      assert [{:stdout, "hello"}] = Renderer.render(Event.text_delta("s", "hello"))
      assert [{:stdout, "\n"}] = Renderer.render(Event.assistant_message("s", "done"))
    end

    test "reasoning, tool calls/results, and notable status go to stderr" do
      assert [{:stderr, "thinking"}] = Renderer.render(Event.reasoning_delta("s", "thinking"))

      assert [{:stderr, line}] =
               Renderer.render(Event.tool_call("s", "c1", "read", %{"path" => "a.txt"}))

      assert line =~ "read"

      assert [{:stderr, "  ok\n"}] =
               Renderer.render(Event.tool_result("s", "c1", %{"ok" => true}))

      assert [{:stderr, "[error]\n"}] = Renderer.render(Event.status("s", "error"))
    end

    test "input/thinking-status events render nothing" do
      assert [] = Renderer.render(Event.user_message("s", "hi"))
      assert [] = Renderer.render(Event.status("s", "thinking"))
    end

    test "context-pressure advisories and warnings go to stderr only (ADR 0020)" do
      snapshot =
        Event.context_pressure("s", %{
          "presentation" => "snapshot",
          "tier" => "none",
          "ratio" => 0.25,
          "model" => "gpt-x"
        })

      assert [] = Renderer.render(snapshot)

      advisory =
        Event.context_pressure("s", %{
          "presentation" => "notice",
          "tier" => "advisory",
          "ratio" => 0.75,
          "model" => "gpt-x"
        })

      assert [{:stderr, line}] = Renderer.render(advisory)
      assert line =~ "75%"

      warning =
        Event.context_pressure("s", %{
          "tier" => "warning",
          "ratio" => 0.85,
          "model" => "gpt-x",
          "next_actions" => [
            %{
              "action" => "inspect_compaction_plan",
              "command" => "pixir compact s --dry-run --json"
            }
          ]
        })

      assert [{:stderr, warning_line}] = Renderer.render(warning)
      assert warning_line =~ "WARNING"
      assert warning_line =~ "pixir compact s --dry-run --json"

      recovery =
        Event.context_pressure("s", %{"tier" => "recovery", "message" => "recovered seq 0..5"})

      assert [{:stderr, recovery_line}] = Renderer.render(recovery)
      assert recovery_line =~ "recovered seq 0..5"
    end
  end

  describe "consume_until_done/1" do
    test "writes answer text to stdout and stops at a terminal status" do
      send(self(), {:pixir_event, Event.text_delta("s", "Hello")})
      send(self(), {:pixir_event, Event.status("s", "done")})

      assert capture_io(fn -> assert :ok = Renderer.consume_until_done() end) == "Hello"
    end

    test "times out when no terminal status arrives" do
      assert :timeout = Renderer.consume_until_done(idle_timeout: 20)
    end
  end

  test "end-to-end: a Turn streams its answer to stdout via the bus" do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-rend-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    {:ok, sid, pid} = SessionSupervisor.start_session(workspace: ws, role: :build)

    on_exit(fn ->
      if Process.alive?(pid), do: DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      File.rm_rf!(ws)
    end)

    {:ok, agent} =
      Agent.start_link(fn ->
        [{:ok, %{text: "All done.", reasoning: "", function_calls: [], finish_reason: :stop}}]
      end)

    :ok = Events.subscribe(sid)

    output =
      capture_io(fn ->
        {:ok, _} =
          Session.start_turn(sid, fn ctx ->
            Turn.run(ctx, "hi", provider: StubProvider, provider_opts: [agent: agent])
          end)

        assert :ok = Renderer.consume_until_done(idle_timeout: 2_000)
      end)

    assert output =~ "All done."
  end
end
