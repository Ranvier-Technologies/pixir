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

    test "bounds Provider warnings at 255/256/257 and emits one suppression footer" do
      for count <- [255, 256, 257] do
        for seq <- 1..count do
          id = "evt_renderer_#{seq}"

          event =
            Event.provider_usage(
              "s",
              %{
                "output_truncation" => %{
                  "status" => "truncated",
                  "reason" => "provider_output_limit",
                  "provider_reason" => "max_tokens",
                  "provider_usage_event_id" => id,
                  "call_role" => "intermediate"
                }
              },
              id: id,
              seq: seq
            )

          send(self(), {:pixir_event, event})
        end

        send(self(), {:pixir_event, Event.status("s", "done")})

        stderr =
          capture_io(:stderr, fn ->
            assert :ok = Renderer.consume_until_done(idle_timeout: 1_000)
          end)

        assert length(Regex.scan(~r/warning: provider output was truncated/, stderr)) ==
                 min(count, 256)

        assert length(Regex.scan(~r/additional provider-output truncation notices/, stderr)) ==
                 if(count == 257, do: 1, else: 0)
      end
    end

    test "deduplicates Provider callbacks by Session/Event including the suppressed 257th" do
      for seq <- 1..257 do
        send(self(), {:pixir_event, output_warning_event("s", seq, "evt_dedup_#{seq}")})
      end

      send(self(), {:pixir_event, output_warning_event("s", 257, "evt_dedup_257")})
      send(self(), {:pixir_event, output_warning_fallback("s", "evt_dedup_257", 257)})
      send(self(), {:pixir_event, Event.status("s", "done")})

      stderr =
        capture_io(:stderr, fn ->
          assert :ok = Renderer.consume_until_done(idle_timeout: 1_000)
        end)

      assert length(Regex.scan(~r/warning: provider output was truncated/, stderr)) == 256
      assert stderr =~ "(total=257, shown=256)"
      refute stderr =~ "total=258"
    end

    test "same Event id in distinct Sessions remains distinct across consume epochs" do
      send(self(), {:pixir_event, output_warning_event("session_a", 1, "evt_shared")})
      send(self(), {:pixir_event, Event.status("session_a", "done")})

      session_a =
        capture_io(:stderr, fn ->
          assert :ok = Renderer.consume_until_done(idle_timeout: 1_000, session_id: "session_a")
        end)

      send(self(), {:pixir_event, output_warning_event("session_b", 1, "evt_shared")})
      send(self(), {:pixir_event, Event.status("session_b", "done")})

      session_b =
        capture_io(:stderr, fn ->
          assert :ok = Renderer.consume_until_done(idle_timeout: 1_000, session_id: "session_b")
        end)

      assert length(Regex.scan(~r/warning: provider output was truncated/, session_a)) == 1
      assert length(Regex.scan(~r/warning: provider output was truncated/, session_b)) == 1
    end

    test "foreign Session warnings fallbacks and terminals cannot contaminate an explicit epoch" do
      send(self(), {:pixir_event, output_warning_event("foreign", 1, "evt_foreign")})
      send(self(), {:pixir_event, output_warning_fallback("foreign", "evt_foreign", 1)})
      send(self(), {:pixir_event, Event.status("foreign", "done")})
      send(self(), {:pixir_event, output_warning_event("target", 1, "evt_target")})
      send(self(), {:pixir_event, Event.status("target", "done")})

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert :ok = Renderer.consume_until_done(idle_timeout: 1_000, session_id: "target")
          end)
        end)

      assert length(Regex.scan(~r/warning: provider output was truncated/, stderr)) == 1
      assert stderr =~ "evt_target"
      refute stderr =~ "evt_foreign"
    end

    test "assistant fallback is counted once when usage is absent and deduped when present" do
      fallback = output_warning_fallback("s", "evt_fallback", 7)
      send(self(), {:pixir_event, fallback})
      send(self(), {:pixir_event, Event.status("s", "done")})

      fallback_only =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert :ok = Renderer.consume_until_done(idle_timeout: 1_000) end)
        end)

      assert length(Regex.scan(~r/warning: provider output was truncated/, fallback_only)) == 1

      send(self(), {:pixir_event, output_warning_event("s", 7, "evt_fallback", "final_answer")})
      send(self(), {:pixir_event, fallback})
      send(self(), {:pixir_event, Event.status("s", "done")})

      provider_and_fallback =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert :ok = Renderer.consume_until_done(idle_timeout: 1_000) end)
        end)

      assert length(Regex.scan(~r/warning: provider output was truncated/, provider_and_fallback)) ==
               1
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

  defp output_warning_event(session_id, seq, id, role \\ "intermediate") do
    Event.provider_usage(
      session_id,
      %{
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => id,
          "call_role" => role
        }
      },
      id: id,
      seq: seq
    )
  end

  defp output_warning_fallback(session_id, id, seq) do
    Event.assistant_message(session_id, "exact",
      metadata: %{
        "output_truncation" => %{
          "status" => "truncated",
          "reason" => "provider_output_limit",
          "provider_reason" => "max_tokens",
          "provider_usage_event_id" => id,
          "provider_usage_seq" => seq,
          "call_role" => "final_answer"
        }
      }
    )
  end
end
