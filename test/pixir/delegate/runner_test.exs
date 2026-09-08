defmodule Pixir.Delegate.RunnerTest do
  use ExUnit.Case, async: false

  alias Pixir.Delegate.Runner

  defmodule EffortAuth do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call(:request_headers, _from, test) do
      send(test, :runtime_effort_auth)
      {:reply, {:ok, []}, test}
    end
  end

  defmodule EffortCustomProvider do
    def stream(_request, opts) do
      send(Keyword.fetch!(opts, :test_pid), :runtime_custom_called)
      {:ok, %{text: "done", reasoning: "", function_calls: [], finish_reason: :stop}}
    end
  end

  defp effort_runtime_opts do
    test = self()
    auth = start_supervised!({EffortAuth, test})

    transport = fn request, acc, reduce ->
      send(test, {:runtime_effort_body, Jason.decode!(request.body)})
      acc = reduce.({:status, 200}, acc)

      event = %{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => []}
      }

      {:ok, reduce.({:data, "data: " <> Jason.encode!(event) <> "\n\n"}, acc)}
    end

    [
      auth: auth,
      transport: transport,
      transport_mode: :http_sse,
      web_search: false,
      native_compaction: false,
      test_pid: test
    ]
  end

  defp effort_runtime_run(path, ws, knobs, provider, provider_opts) do
    opts = [
      workspace: ws,
      provider: provider,
      provider_opts: provider_opts,
      permission_mode: :read_only
    ]

    step =
      Map.merge(
        %{
          "id" => "effort",
          "task" => "inspect effort",
          "agent" => "explorer",
          "workspace_mode" => "shared"
        },
        knobs
      )

    case path do
      :native ->
        {:ok, sid, _pid} = Pixir.SessionSupervisor.start_session(workspace: ws)
        on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)

        case Pixir.Subagents.spawn_agent(sid, step, opts) do
          {:ok, child} ->
            assert {:ok, [completed]} =
                     Pixir.Subagents.wait(sid, [child["id"]], 5_000, workspace: ws)

            assert completed["status"] == "completed"
            Pixir.Subagents.close(sid, child["id"], workspace: ws)
            {:ok, completed}

          error ->
            error
        end

      :workflow ->
        {:ok, sid, _pid} = Pixir.SessionSupervisor.start_session(workspace: ws)
        on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)
        Pixir.Workflows.run(sid, %{"steps" => [step]}, opts)

      strategy ->
        spec =
          if strategy == "subagents" do
            %{
              "task" => "inspect effort",
              "subagents" => Map.put(knobs, "workspace_mode", "shared")
            }
          else
            %{"steps" => [step]}
          end

        spec = Map.merge(spec, %{"contract_version" => 1, "strategy" => strategy})

        Runner.run(
          %{workspace: ws},
          spec,
          %{"strategy" => strategy, "planned_child_count" => 1},
          opts
        )
    end
  end

  for path <- [:native, :workflow, "subagents", "workflow"] do
    @effort_path path

    test "#{inspect(path)} actual runtime transmits explicit and Config Astra max without downgrading" do
      with_pixir_home("pixir-effort-runtime", fn ->
        ws = tmp_workspace("pixir-effort-runtime", stop_sessions: true)
        provider_opts = effort_runtime_opts()
        config_path = Path.join(System.fetch_env!("PIXIR_HOME"), "config.json")

        for {config, knobs, extra, expected_model, expected_effort} <- [
              {%{}, %{"model" => "gpt-6-astra", "reasoning_effort" => "max"}, [], "gpt-6-astra",
               "max"},
              {%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}}, %{}, [],
               "gpt-6-astra", "max"},
              {%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}},
               %{"model" => "gpt-5.5", "reasoning_effort" => "high"}, [], "gpt-5.5", "high"},
              {%{
                 "model" => "gpt-5.5",
                 "reasoning" => %{"effort" => "max"},
                 "responses_backend" => effort_open_backend()
               }, %{"model" => "gpt-6-astra"}, [responses_backend: %{"mode" => "chatgpt_codex"}],
               "gpt-6-astra", "max"}
            ] do
          File.write!(config_path, Jason.encode!(config))

          assert {:ok, _} =
                   effort_runtime_run(
                     @effort_path,
                     ws,
                     knobs,
                     Pixir.Provider,
                     extra ++ provider_opts
                   )

          assert_receive :runtime_effort_auth
          assert_receive {:runtime_effort_body, body}
          assert body["model"] == expected_model
          assert body["reasoning"] == %{"effort" => expected_effort}
          refute_receive :runtime_custom_called
        end
      end)
    end

    test "#{inspect(path)} runtime refuses incompatible effective max before auth transport or custom callback" do
      with_pixir_home("pixir-effort-runtime-reject", fn ->
        ws = tmp_workspace("pixir-effort-runtime-reject", stop_sessions: true)
        provider_opts = effort_runtime_opts()
        config_path = Path.join(System.fetch_env!("PIXIR_HOME"), "config.json")

        for {config, knobs, provider, extra} <- [
              {%{}, %{"model" => "gpt-6-astra", "reasoning_effort" => "max"},
               EffortCustomProvider, []},
              {%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}}, %{},
               EffortCustomProvider, []},
              {%{}, %{"model" => "gpt-5.5", "reasoning_effort" => "max"}, Pixir.Provider,
               [model: "gpt-6-astra"]},
              {%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}}, %{},
               Pixir.Provider, [model: "gpt-5.5"]},
              {%{}, %{"model" => "gpt-6-astra", "reasoning_effort" => "max"}, Pixir.Provider,
               [responses_backend: effort_open_backend()]},
              {%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}}, %{},
               Pixir.Provider, [responses_backend: effort_open_backend()]},
              {%{}, %{"model" => "gpt-6-astra", "reasoning_effort" => "max"}, Pixir.Provider,
               [base_url: "https://example.invalid"]},
              {%{}, %{}, EffortCustomProvider, [model: "gpt-6-astra", reasoning_effort: "max"]}
            ] do
          File.write!(config_path, Jason.encode!(config))

          assert {:error, error} =
                   effort_runtime_run(@effort_path, ws, knobs, provider, extra ++ provider_opts)

          kind = get_in(error, [:error, :kind]) || error["kind"]

          assert kind ==
                   if(@effort_path in [:native, :workflow],
                     do: :invalid_config,
                     else: "invalid_config"
                   )

          refute_receive :runtime_effort_auth
          refute_receive {:runtime_effort_body, _}
          refute_receive :runtime_custom_called
        end
      end)
    end
  end

  test "native follow-up revalidates changed Config max before a custom callback" do
    with_pixir_home("pixir-effort-followup", fn ->
      ws = tmp_workspace("pixir-effort-followup", stop_sessions: true)
      config_path = Path.join(System.fetch_env!("PIXIR_HOME"), "config.json")
      File.write!(config_path, Jason.encode!(%{"model" => "gpt-6-astra"}))
      {:ok, sid, _pid} = Pixir.SessionSupervisor.start_session(workspace: ws)
      on_exit(fn -> Pixir.SessionSupervisor.stop_session(sid) end)

      assert {:ok, child} =
               Pixir.Subagents.spawn_agent(
                 sid,
                 %{"task" => "initial", "agent" => "explorer", "workspace_mode" => "shared"},
                 workspace: ws,
                 provider: EffortCustomProvider,
                 provider_opts: [test_pid: self()]
               )

      assert {:ok, [%{"status" => "completed"}]} =
               Pixir.Subagents.wait(sid, [child["id"]], 5_000, workspace: ws)

      assert_receive :runtime_custom_called

      File.write!(
        config_path,
        Jason.encode!(%{"model" => "gpt-6-astra", "reasoning" => %{"effort" => "max"}})
      )

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Pixir.Subagents.send_input(sid, child["id"], "follow up", workspace: ws)

      refute_receive :runtime_custom_called
      assert {:ok, _} = Pixir.Subagents.close(sid, child["id"], workspace: ws)
    end)
  end

  defp effort_open_backend do
    %{
      "mode" => "open_responses",
      "responses_url" => "https://api.openai.com/v1/responses",
      "auth" => %{"policy" => "none"}
    }
  end

  defp tmp_workspace(prefix, opts \\ []) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(path)

    on_exit(fn ->
      if opts[:stop_sessions] do
        # Runner.run creates durable parents even on spawn refusal. Close their
        # Manager children and stop the owned Sessions before deleting fixtures;
        # otherwise lease release can recreate files during File.rm_rf!.
        ids =
          Path.wildcard(Path.join([path, ".pixir", "sessions", "*.ndjson"]))
          |> Enum.map(&Path.basename(&1, ".ndjson"))

        for sid <- ids do
          assert {:ok, children} = Pixir.Subagents.list(sid, workspace: path)

          for child <- children, child["status"] != "closed" do
            assert {:ok, _} = Pixir.Subagents.close(sid, child["id"], workspace: path)
          end
        end

        for sid <- ids, do: assert({:ok, _} = Pixir.SessionSupervisor.stop_session(sid))
      end

      File.rm_rf!(path)
    end)

    path
  end

  defp with_pixir_home(prefix, fun) do
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    previous_home = System.get_env("PIXIR_HOME")

    File.mkdir_p!(home)
    System.put_env("PIXIR_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end)

    fun.()
  end

  defp write_raw_session_log(workspace, session_id, events) do
    sessions_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions_dir)

    body = Enum.map_join(events, "", fn event -> Jason.encode!(event) <> "\n" end)
    File.write!(Path.join(sessions_dir, "#{session_id}.ndjson"), body)
  end

  defp write_corrupt_session_log(workspace, session_id, valid_events) do
    sessions_dir = Path.join([workspace, ".pixir", "sessions"])
    File.mkdir_p!(sessions_dir)

    body =
      Enum.map_join(valid_events, "", fn event -> Jason.encode!(event) <> "\n" end) <>
        ~s({"id":"truncated")

    File.write!(Path.join(sessions_dir, "#{session_id}.ndjson"), body)
  end

  defp raw_event(session_id, seq, type, data) do
    %{
      "id" => "event-#{seq}",
      "session_id" => session_id,
      "seq" => seq,
      "ts" => "2026-07-03T00:00:00Z",
      "type" => type,
      "data" => data
    }
  end

  defp read_session_events(workspace, session_id) do
    [workspace, ".pixir", "sessions", "#{session_id}.ndjson"]
    |> Path.join()
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp run_child_projection(workspace, child, mode) do
    spec = projection_spec(mode)
    terminal_status = child["status"]
    completed = if terminal_status == "completed", do: 1, else: 0
    failed = if terminal_status == "failed", do: 1, else: 0
    outcome_status = if completed == 1, do: "completed", else: "partial"

    spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

    wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
      {:ok,
       %{
         "status" => outcome_status,
         "complete" => true,
         "counts" => %{
           "completed" => completed,
           "failed" => failed,
           "timed_out" => 0,
           "cancelled" => 0,
           "detached" => 0,
           "incomplete" => 0
         },
         "subagents" => [child],
         "summary" => outcome_status
       }}
    end

    assert {:ok, %{"children" => [projected]}} =
             Runner.run(
               %{workspace: workspace},
               spec,
               %{"strategy" => "subagents", "planned_child_count" => 1},
               spawn_agent: spawn_agent,
               wait_outcome: wait_outcome
             )

    projected
  end

  defp projection_spec("read_only") do
    %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "mode" => "read_only",
      "task" => "project one child"
    }
  end

  defp projection_spec("bounded_write") do
    %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "mode" => "bounded_write",
      "task" => "project one writer",
      "write_policy" => %{
        "version" => 1,
        "metadata" => %{"id" => "guided-resume-test"},
        "allow_writes" => ["notes/out.md"]
      }
    }
  end

  test "completed shared writer carries a landing manifest in the delegate result" do
    with_pixir_home("pixir-delegate-landing-home", fn ->
      ws = tmp_workspace("pixir-delegate-landing")
      child_session_id = "20260825T000001-landing"
      File.mkdir_p!(Path.join(ws, "notes"))
      File.write!(Path.join(ws, "notes/out.md"), "landed")

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "tool_call", %{
          "call_id" => "write-landed",
          "name" => "write",
          "args" => %{"path" => "notes/out.md", "content" => "landed"}
        }),
        raw_event(child_session_id, 2, "tool_result", %{
          "call_id" => "write-landed",
          "ok" => true,
          "output" => "written"
        })
      ])

      child = %{
        "id" => "subagent_landing",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "completed",
        "summary" => "done",
        "task" => "write notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "child_log_path" => Path.join(ws, "landing.ndjson"),
        "next_actions" => []
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "complete" => true,
           "counts" => %{
             "completed" => 1,
             "failed" => 0,
             "timed_out" => 0,
             "cancelled" => 0,
             "detached" => 0,
             "incomplete" => 0
           },
           "subagents" => [child],
           "summary" => "delegate completed."
         }}
      end

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 projection_spec("bounded_write"),
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert payload["landing_manifest"] == [
               %{
                 "child_id" => "subagent_landing",
                 "workspace" => ws,
                 "produced" => [
                   %{
                     "kind" => "shared_workspace_files",
                     "paths" => [
                       %{
                         "path" => "notes/out.md",
                         "resolvable" => true,
                         "exists_in_parent" => true,
                         "drift" => false
                       }
                     ],
                     "next_action" => %{
                       "action" => "verify_and_commit",
                       "paths" => ["notes/out.md"]
                     }
                   }
                 ]
               }
             ]

      assert payload["summary"] ==
               "delegate completed.\n\n" <>
                 Pixir.Subagents.reverification_directive() <>
                 "\n\nLanding manifest:\n" <>
                 "- subagent_landing\n" <>
                 "  workspace: #{ws}\n" <>
                 "  produced: shared-workspace files\n" <>
                 "  changed paths:\n" <>
                 "    - notes/out.md (exists_in_parent=true, drift=false)\n" <>
                 "  next action: verify and commit paths [\"notes/out.md\"]"
    end)
  end

  test "transport-dead writer projects guided resume with write-safe notes" do
    with_pixir_home("pixir-delegate-writer-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-writer-resume")
      child_session_id = "20260710T000001-writer"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "provider_http_error",
          "error_message" => "provider transport failed",
          "details" => %{
            "retryable" => true,
            "type" => "service_unavailable_error"
          }
        })
      ])

      child = %{
        "id" => "subagent_writer",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "failed",
        "summary" => "provider transport failed",
        "task" => "write notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "auto",
        "write_policy" => %{"allow_writes" => ["notes/out.md"]},
        "reason" => "provider_error",
        "child_log_path" => Path.join(ws, "writer.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "bounded_write")

      assert projected["recovery"]["kind"] == "resume_suggested"

      assert projected["recovery"]["reason"] ==
               "terminal transport error: service_unavailable_error"

      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"

      notes = projected["recovery"]["notes"]

      assert "The child Log is the source of truth; the resumed turn continues with context intact." in notes

      assert "Inspect the child Log for already-applied writes before resuming so work is not duplicated." in notes

      assert "A stale writer lease fails closed on purpose; inspect with pixir diagnose and never force-release it as a default." in notes
    end)
  end

  test "transport-dead read-only worker without capability signal omits writer guidance" do
    with_pixir_home("pixir-delegate-reader-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-reader-resume")
      child_session_id = "20260710T000002-reader"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_closed",
          "error_message" => "websocket closed"
        })
      ])

      child = %{
        "id" => "subagent_reader",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "failed",
        "summary" => "websocket closed",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "reason" => "provider_error",
        "retry_attempts" => 2,
        "retry_max_attempts" => 2,
        "current_attempt_index" => 2,
        "retry_history" => [
          %{"attempt_index" => 0, "error_kind" => "websocket_closed"},
          %{"attempt_index" => 1, "error_kind" => "websocket_closed"}
        ],
        "child_log_path" => Path.join(ws, "reader.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      assert projected["recovery"] == %{
               "kind" => "resume_suggested",
               "reason" => "terminal transport error: websocket_closed"
             }

      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["retry_attempts"] == 2
      assert length(projected["retry_history"]) == 2
    end)
  end

  test "detached child with transport evidence projects guided resume" do
    with_pixir_home("pixir-delegate-detached-resume-home", fn ->
      ws = tmp_workspace("pixir-delegate-detached-resume")
      child_session_id = "20260710T000003-detached"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_read_failed",
          "error_message" => "Could not read WebSocket frame.",
          "details" => %{"reason" => ":closed"}
        })
      ])

      child = %{
        "id" => "subagent_detached",
        "child_session_id" => child_session_id,
        "agent" => "worker",
        "status" => "detached",
        "summary" => "child from a previous Pixir runtime",
        "task" => "write notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "auto",
        "write_policy" => %{"allow_writes" => ["notes/out.md"]},
        "reason" => "detached",
        "child_log_path" => Path.join(ws, "detached.ndjson"),
        "next_actions" => []
      }

      # The most common real-world shape: the runtime that owned the child
      # died, the child shows detached after restart, and its Log carries the
      # transport death — guided resume must reach it too.
      projected = run_child_projection(ws, child, "bounded_write")

      assert projected["recovery"]["kind"] == "resume_suggested"
      assert projected["recovery"]["reason"] =~ "websocket_read_failed"
      assert is_binary(projected["resume_command"])
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"
      assert Enum.any?(projected["recovery"]["notes"], &(&1 =~ "lease"))
    end)
  end

  test "non-transport child failure keeps the existing recovery shape" do
    with_pixir_home("pixir-delegate-nontransport-home", fn ->
      ws = tmp_workspace("pixir-delegate-nontransport")
      child_session_id = "20260710T000003-nontransport"

      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "tool_error",
          "error_kind" => "invalid_args",
          "error_message" => "invalid task"
        })
      ])

      child = %{
        "id" => "subagent_nontransport",
        "child_session_id" => child_session_id,
        "agent" => "explorer",
        "status" => "failed",
        "summary" => "invalid task",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "permission_mode" => "read_only",
        "reason" => "tool_error",
        "child_log_path" => Path.join(ws, "nontransport.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      refute Map.has_key?(projected, "recovery")
      assert projected["resume_command"] =~ "pixir resume #{child_session_id}"
      assert projected["diagnose_command"] =~ "pixir diagnose session #{child_session_id}"
    end)
  end

  test "completed child stays untouched even with stale transport evidence" do
    with_pixir_home("pixir-delegate-completed-home", fn ->
      ws = tmp_workspace("pixir-delegate-completed")
      child_session_id = "20260710T000004-completed"

      # The stale evidence rides the child Log — the source the projection
      # actually reads when results collapse the reason — not an inline field.
      write_raw_session_log(ws, child_session_id, [
        raw_event(child_session_id, 1, "turn_failed", %{
          "terminal_status" => "provider_error",
          "error_kind" => "websocket_read_failed",
          "error_message" => "stale transport event from an earlier attempt",
          "details" => %{"reason" => ":closed"}
        })
      ])

      child = %{
        "id" => "subagent_completed",
        "child_session_id" => child_session_id,
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect notes",
        "workspace_mode" => "shared",
        "permission_mode" => "read_only",
        "child_log_path" => Path.join(ws, "completed.ndjson"),
        "next_actions" => []
      }

      projected = run_child_projection(ws, child, "read_only")

      refute Map.has_key?(projected, "recovery")
      refute Map.has_key?(projected, "resume_command")
      refute Map.has_key?(projected, "diagnose_command")
    end)
  end

  test "child projection preserves validated pre-bound output warning reasons" do
    with_pixir_home("pixir-delegate-output-reasons-home", fn ->
      ws = tmp_workspace("pixir-delegate-output-reasons")
      child_sid = "child_output_reasons"

      warnings =
        for seq <- 1..64 do
          %{
            "kind" => "provider_output_truncated",
            "severity" => "warning",
            "child_session_id" => child_sid,
            "provider_usage_event_id" => "evt_#{seq}",
            "provider_usage_seq" => seq,
            "reason" => "provider_output_limit",
            "provider_reason" => "max_tokens",
            "call_role" => "intermediate"
          }
        end

      child = %{
        "id" => "subagent_output_reasons",
        "child_session_id" => child_sid,
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect",
        "workspace_mode" => "shared",
        "workspace" => ws,
        "child_log_path" => Path.join(ws, "child.ndjson"),
        "next_actions" => [],
        "output_warning_count" => 65,
        "output_warnings" => warnings,
        "output_warning_reasons" => [
          "provider_output_limit",
          "provider_content_filter",
          "unsafe"
        ],
        "output_warnings_truncated" => true
      }

      projected = run_child_projection(ws, child, "read_only")

      assert projected["output_warning_count"] == 65
      assert length(projected["output_warnings"]) == 64

      assert projected["output_warning_reasons"] == [
               "provider_output_limit",
               "provider_content_filter",
               "unsafe"
             ]
    end)
  end

  test "nested workflow shell cannot override root max_concurrency during rehearsal" do
    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "max_concurrency" => 2,
      "workflow" => %{
        # Invalid if it leaks into Pixir.Workflows normalization.
        "max_concurrency" => 0,
        "steps" => [%{"id" => "inspect", "task" => "inspect", "agent" => "explorer"}]
      }
    }

    assert {:ok, %{"summary" => %{"max_concurrency" => 2, "steps" => 1}}} =
             Runner.rehearse_workflow_spec(spec, "read_only")
  end

  test "nested workflow shell cannot inject template refs during rehearsal" do
    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "workflow" => %{
        # Triggers template instantiation (and fails on the ghost ref) if it
        # leaks past the shell-key take into Pixir.Workflows normalization.
        "template_id" => "ghost-skill/ghost-template",
        "steps" => [%{"id" => "inspect", "task" => "inspect", "agent" => "explorer"}]
      }
    }

    assert {:ok, %{"summary" => %{"steps" => 1}}} =
             Runner.rehearse_workflow_spec(spec, "read_only")
  end

  test "root limits knobs drive the normalized wait horizon end to end" do
    with_pixir_home("pixir-delegate-root-limits-home", fn ->
      ws = tmp_workspace("pixir-delegate-root-limits")
      parent = self()

      child = %{
        "id" => "agent-1",
        "child_session_id" => "20260721T000000-limits",
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect timeout configuration",
        "workspace_mode" => "shared",
        "workspace" => ws
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, timeout_ms, _opts ->
        send(parent, {:wait_horizon_ms, timeout_ms})

        {:ok,
         %{
           "status" => "completed",
           "complete" => true,
           "counts" => %{
             "completed" => 1,
             "failed" => 0,
             "timed_out" => 0,
             "cancelled" => 0,
             "detached" => 0,
             "incomplete" => 0
           },
           "subagents" => [child],
           "summary" => "completed"
         }}
      end

      base = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "mode" => "read_only",
        "task" => "inspect timeout configuration"
      }

      run = fn limits ->
        assert {:ok, _payload} =
                 Runner.run(
                   %{workspace: ws},
                   Map.put(base, "limits", limits),
                   %{"strategy" => "subagents", "planned_child_count" => 1},
                   spawn_agent: spawn_agent,
                   wait_outcome: wait_outcome
                 )
      end

      # An explicit wait_horizon_ms knob reaches the wait boundary untouched when
      # the configured child budget makes that caller horizon admissible.
      run.(%{"wait_horizon_ms" => 55_555, "child_timeout_ms" => 55_555})
      assert_received {:wait_horizon_ms, 55_555}

      # The legacy knob cascades legacy -> delegate -> wait horizon.
      run.(%{"timeout_ms" => 44_444})
      assert_received {:wait_horizon_ms, 44_444}
    end)
  end

  test "precomputed horizon evidence fails closed when facts are absent malformed or contradictory" do
    valid = %{
      "strategy" => "subagents",
      "effective_timeout_ms" => 100_000,
      "estimated_critical_path_ms" => 120_000,
      "waves" => 2,
      "suggested_timeout_ms" => 120_000,
      "per_wave_budget_ms" => 60_000,
      "wave_budgets_ms" => [60_000, 60_000]
    }

    invalid_cases = [
      {"missing critical path", nil},
      {"missing required fact", Map.delete(valid, "effective_timeout_ms")},
      {"nil effective horizon", Map.put(valid, "effective_timeout_ms", nil)},
      {"nil estimate", Map.put(valid, "estimated_critical_path_ms", nil)},
      {"non-numeric estimate", Map.put(valid, "estimated_critical_path_ms", "120000")},
      {"zero horizon", Map.put(valid, "effective_timeout_ms", 0)},
      {"negative wave count", Map.put(valid, "waves", -1)},
      {"missing arithmetic", Map.drop(valid, ["per_wave_budget_ms", "wave_budgets_ms"])},
      {"malformed wave budgets", Map.put(valid, "wave_budgets_ms", [60_000, nil])},
      {"suggestion below estimate", Map.put(valid, "suggested_timeout_ms", 119_999)},
      {"per-wave arithmetic mismatch", Map.put(valid, "per_wave_budget_ms", 59_999)},
      {"wave count mismatch", Map.put(valid, "wave_budgets_ms", [120_000])},
      {"wave sum mismatch", Map.put(valid, "wave_budgets_ms", [60_000, 59_999])}
    ]

    for {label, details} <- invalid_cases do
      assert {:error,
              %{
                "ok" => false,
                "status" => "rejected",
                "kind" => "invalid_horizon_evidence",
                "details" => evidence_errors
              }} = Runner.admit_horizon_details(%{allow_short_horizon?: true}, details),
             label

      assert evidence_errors["missing_fields"] != [] or
               evidence_errors["malformed_fields"] != [] or
               evidence_errors["contradictions"] != [],
             label
    end

    secret = "operator-secret-/private/worktree"

    assert {:error, secret_safe_error} =
             Runner.admit_horizon_details(
               %{allow_short_horizon?: true},
               Map.put(valid, "effective_timeout_ms", secret)
             )

    refute inspect(secret_safe_error) =~ secret
  end

  test "runner rejects inconsistent planned child counts before Session or spawn" do
    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "must not spawn",
      "subagents" => %{"max_threads" => 1, "timeout_ms" => 60_000}
    }

    for planned_child_count <- [nil, "1", 0] do
      ws = tmp_workspace("pixir-delegate-invalid-horizon-input")
      test_pid = self()

      spawn_agent = fn _parent_session_id, _args, _opts ->
        send(test_pid, {:unexpected_horizon_spawn, planned_child_count})
        {:error, :must_not_spawn}
      end

      assert {:error, %{"kind" => "invalid_spec"}} =
               Runner.run(
                 %{workspace: ws, timeout_ms: 100_000},
                 spec,
                 %{
                   "strategy" => "subagents",
                   "planned_child_count" => planned_child_count
                 },
                 spawn_agent: spawn_agent
               )

      refute_received {:unexpected_horizon_spawn, ^planned_child_count}
      refute File.exists?(Path.join([ws, ".pixir", "sessions"]))
    end
  end

  test "short-horizon override requires exact boolean true" do
    ws = tmp_workspace("pixir-delegate-exact-horizon-override")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "tasks" => ["first", "second"],
      "subagents" => %{"max_threads" => 1, "timeout_ms" => 60_000}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

    for hostile_truthy <- ["true", :yes, 1, [true], %{value: true}] do
      assert {:error, %{"kind" => "horizon_shorter_than_critical_path"}} =
               Runner.admit_horizon(
                 %{
                   workspace: ws,
                   timeout_ms: 100_000,
                   allow_short_horizon?: hostile_truthy
                 },
                 spec,
                 spec_meta
               )
    end

    assert {:ok,
            %{
              "effective_timeout_ms" => 100_000,
              "estimated_critical_path_ms" => 120_000,
              "waves" => 2,
              "suggested_timeout_ms" => 120_000
            }} =
             Runner.admit_horizon(
               %{workspace: ws, timeout_ms: 100_000, allow_short_horizon?: true},
               spec,
               spec_meta
             )
  end

  test "explicit wait horizons from request and limits are independently repairable" do
    ws = tmp_workspace("pixir-delegate-explicit-wait-recovery")

    base_spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "one child with the runtime floor",
      "limits" => %{
        "child_timeout_ms" => 120_000,
        "delegate_timeout_ms" => 150_000
      }
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error,
            %{
              "details" => %{
                "wait_horizon_explicit" => true,
                "effective_timeout_ms" => 100_000,
                "estimated_critical_path_ms" => 120_000,
                "suggested_timeout_ms" => 120_000,
                "next_actions" => request_actions
              }
            }} =
             Runner.admit_horizon(
               %{workspace: ws, wait_horizon_ms: 100_000},
               base_spec,
               spec_meta
             )

    assert "increase_wait_horizon_to_suggested_timeout_ms" in request_actions
    refute "increase_delegate_timeout_to_suggested_timeout_ms" in request_actions

    # Applying the prescribed request knob is sufficient without changing the spec.
    assert {:ok, nil} =
             Runner.admit_horizon(
               %{workspace: ws, wait_horizon_ms: 120_000},
               base_spec,
               spec_meta
             )

    limits_spec = put_in(base_spec, ["limits", "wait_horizon_ms"], 100_000)

    assert {:error, %{"details" => %{"next_actions" => limits_actions}}} =
             Runner.admit_horizon(%{workspace: ws}, limits_spec, spec_meta)

    assert "increase_wait_horizon_to_suggested_timeout_ms" in limits_actions
    refute "increase_delegate_timeout_to_suggested_timeout_ms" in limits_actions

    repaired_limits_spec = put_in(limits_spec, ["limits", "wait_horizon_ms"], 120_000)
    assert {:ok, nil} = Runner.admit_horizon(%{workspace: ws}, repaired_limits_spec, spec_meta)
  end

  test "workflow explicit wait and workflow horizons prescribe their combined fixed point" do
    ws = tmp_workspace("pixir-delegate-workflow-explicit-wait-recovery")

    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "timeout_ms" => 100_000,
      "limits" => %{"delegate_timeout_ms" => 150_000},
      "steps" => [
        %{"id" => "first", "task" => "first"},
        %{"id" => "second", "task" => "second", "depends_on" => ["first"]}
      ]
    }

    assert {:error,
            %{
              "details" => %{
                "wait_horizon_explicit" => true,
                "declared_workflow_timeout_explicit" => true,
                "suggested_timeout_ms" => 240_000,
                "next_actions" => next_actions
              }
            }} =
             Runner.admit_horizon(
               %{workspace: ws, wait_horizon_ms: 100_000},
               spec,
               %{"strategy" => "workflow", "planned_child_count" => 2}
             )

    assert "increase_wait_horizon_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
    refute "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
  end

  test "omitted workflow timeout repairs explicit wait and derived delegate horizons once" do
    ws = tmp_workspace("pixir-delegate-workflow-derived-timeout-recovery")

    base_spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "limits" => %{"delegate_timeout_ms" => 150_000},
      "steps" => [
        %{"id" => "first", "task" => "first"},
        %{"id" => "second", "task" => "second", "depends_on" => ["first"]}
      ]
    }

    spec_meta = %{"strategy" => "workflow", "planned_child_count" => 2}

    cases = [
      %{
        source: "request.wait_horizon_ms",
        initial_request: %{workspace: ws, wait_horizon_ms: 100_000},
        initial_spec: base_spec,
        wait_repaired_request: %{workspace: ws, wait_horizon_ms: 240_000},
        wait_repaired_spec: base_spec,
        fully_repaired_request: %{workspace: ws, wait_horizon_ms: 240_000},
        fully_repaired_spec: put_in(base_spec, ["limits", "delegate_timeout_ms"], 240_000)
      },
      %{
        source: "limits.wait_horizon_ms",
        initial_request: %{workspace: ws},
        initial_spec: put_in(base_spec, ["limits", "wait_horizon_ms"], 100_000),
        wait_repaired_request: %{workspace: ws},
        wait_repaired_spec: put_in(base_spec, ["limits", "wait_horizon_ms"], 240_000),
        fully_repaired_request: %{workspace: ws},
        fully_repaired_spec:
          base_spec
          |> put_in(["limits", "wait_horizon_ms"], 240_000)
          |> put_in(["limits", "delegate_timeout_ms"], 240_000)
      }
    ]

    for scenario <- cases do
      assert {:error,
              %{
                "kind" => "horizon_shorter_than_critical_path",
                "details" => %{
                  "caller_horizon_ms" => 100_000,
                  "wait_horizon_explicit" => true,
                  "declared_workflow_timeout_ms" => 150_000,
                  "declared_workflow_timeout_explicit" => false,
                  "effective_timeout_ms" => 100_000,
                  "estimated_critical_path_ms" => 200_000,
                  "suggested_timeout_ms" => 240_000,
                  "next_actions" => [
                    "increase_wait_horizon_and_delegate_timeout_to_suggested_timeout_ms",
                    "reduce_workflow_dependency_waves",
                    "reduce_workflow_step_timeouts",
                    "rerun_with_--allow-short-horizon"
                  ]
                }
              }} =
               Runner.admit_horizon(
                 scenario.initial_request,
                 scenario.initial_spec,
                 spec_meta
               ),
             scenario.source

      # Raising only the explicit wait knob leaves the derived delegate horizon
      # binding, so the first recovery suggestion must now target only delegate.
      assert {:error,
              %{
                "kind" => "horizon_shorter_than_critical_path",
                "details" => %{
                  "caller_horizon_ms" => 240_000,
                  "wait_horizon_explicit" => true,
                  "declared_workflow_timeout_ms" => 150_000,
                  "declared_workflow_timeout_explicit" => false,
                  "effective_timeout_ms" => 150_000,
                  "estimated_critical_path_ms" => 240_000,
                  "suggested_timeout_ms" => 240_000,
                  "next_actions" => [
                    "increase_delegate_timeout_to_suggested_timeout_ms",
                    "reduce_workflow_dependency_waves",
                    "reduce_workflow_step_timeouts",
                    "rerun_with_--allow-short-horizon"
                  ]
                }
              }} =
               Runner.admit_horizon(
                 scenario.wait_repaired_request,
                 scenario.wait_repaired_spec,
                 spec_meta
               ),
             scenario.source

      # Applying both values from the initial combined action is sufficient in
      # one edit while the workflow itself and its omitted step budgets stay unchanged.
      assert {:ok, nil} =
               Runner.admit_horizon(
                 scenario.fully_repaired_request,
                 scenario.fully_repaired_spec,
                 spec_meta
               ),
             scenario.source
    end
  end

  test "workflow admission uses the delegate timeout when estimating sequential steps" do
    ws = tmp_workspace("pixir-delegate-workflow-estimate-timeout")

    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "steps" => [
        %{
          "id" => "first",
          "task" => "first",
          "agent" => "explorer",
          "timeout_ms" => 200_000
        },
        %{
          "id" => "second",
          "task" => "second",
          "agent" => "explorer",
          "depends_on" => ["first"],
          "timeout_ms" => 200_000
        }
      ]
    }

    spec_meta = %{"strategy" => "workflow", "planned_child_count" => 2}

    assert {:error,
            %{
              "kind" => "horizon_shorter_than_critical_path",
              "details" => %{
                "effective_timeout_ms" => 350_000,
                "estimated_critical_path_ms" => 400_000,
                "waves" => 2,
                "suggested_timeout_ms" => 400_000
              }
            }} =
             Runner.admit_horizon(%{workspace: ws, timeout_ms: 350_000}, spec, spec_meta)
  end

  test "workflow-only binding reports its knobs and is repaired by changing only the workflow timeout" do
    ws = tmp_workspace("pixir-delegate-workflow-completion-budget")

    base = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "steps" => [
        %{
          "id" => "first",
          "task" => "first",
          "agent" => "explorer",
          "timeout_ms" => 100_000
        },
        %{
          "id" => "second",
          "task" => "second",
          "agent" => "explorer",
          "depends_on" => ["first"],
          "timeout_ms" => 100_000
        }
      ]
    }

    spec = Map.put(base, "timeout_ms", 150_000)
    request = %{workspace: ws, wait_horizon_ms: 350_000}
    spec_meta = %{"strategy" => "workflow", "planned_child_count" => 2}

    assert {:error,
            %{
              "kind" => "horizon_shorter_than_critical_path",
              "details" => %{
                "caller_horizon_ms" => 350_000,
                "declared_workflow_timeout_ms" => 150_000,
                "declared_workflow_timeout_explicit" => true,
                "effective_timeout_ms" => 150_000,
                "estimated_critical_path_ms" => 200_000,
                "waves" => 2,
                "suggested_timeout_ms" => 200_000,
                "strategy" => "workflow",
                "json_pointer" => "/steps/0/timeout_ms",
                "next_actions" => next_actions
              }
            }} = Runner.admit_horizon(request, spec, spec_meta)

    assert "increase_workflow_timeout_to_suggested_timeout_ms" in next_actions
    refute "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
    refute "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions

    assert {:ok, nil} =
             Runner.admit_horizon(request, Map.put(spec, "timeout_ms", 200_000), spec_meta)

    # Preserve the legacy delegate-timeout fallback contract when no workflow
    # timeout is declared.
    assert {:error, %{"details" => %{"effective_timeout_ms" => 150_000}}} =
             Runner.admit_horizon(
               request,
               Map.put(base, "limits", %{"delegate_timeout_ms" => 150_000}),
               spec_meta
             )
  end

  test "workflow admission uses the shorter caller horizon when workflow timeout is longer" do
    ws = tmp_workspace("pixir-delegate-workflow-caller-horizon")

    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "timeout_ms" => 350_000,
      "steps" => [
        %{
          "id" => "first",
          "task" => "first",
          "agent" => "explorer",
          "timeout_ms" => 100_000
        },
        %{
          "id" => "second",
          "task" => "second",
          "agent" => "explorer",
          "depends_on" => ["first"],
          "timeout_ms" => 100_000
        }
      ]
    }

    assert {:error,
            %{
              "kind" => "horizon_shorter_than_critical_path",
              "details" => %{
                "effective_timeout_ms" => 150_000,
                "estimated_critical_path_ms" => 200_000,
                "waves" => 2,
                "suggested_timeout_ms" => 200_000
              }
            }} =
             Runner.admit_horizon(
               %{workspace: ws, wait_horizon_ms: 150_000},
               spec,
               %{"strategy" => "workflow", "planned_child_count" => 2}
             )
  end

  test "workflow caller horizon caps both admission estimation and runtime workflow timeout" do
    with_pixir_home("pixir-delegate-workflow-effective-horizon-home", fn ->
      ws = tmp_workspace("pixir-delegate-workflow-effective-horizon")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "read_only",
        "timeout_ms" => 600_000,
        "steps" => [
          %{
            "id" => "first",
            "task" => "first",
            "agent" => "explorer",
            "timeout_ms" => 200_000
          },
          %{
            "id" => "second",
            "task" => "second",
            "agent" => "explorer",
            "depends_on" => ["first"],
            "timeout_ms" => 200_000
          }
        ]
      }

      spec_meta = %{"strategy" => "workflow", "planned_child_count" => 2}
      request = %{workspace: ws, wait_horizon_ms: 120_000}

      assert {:ok,
              %{
                "caller_horizon_ms" => 120_000,
                "declared_workflow_timeout_ms" => 600_000,
                "declared_workflow_timeout_explicit" => true,
                "effective_timeout_ms" => 120_000,
                "estimated_critical_path_ms" => 240_000,
                "waves" => 2,
                "suggested_timeout_ms" => 400_000
              }} = Runner.critical_path(request, spec, spec_meta, [])

      assert {:error, rejection} = Runner.admit_horizon(request, spec, spec_meta)
      assert rejection["kind"] == "horizon_shorter_than_critical_path"

      assert rejection["details"]["caller_horizon_ms"] == 120_000
      assert rejection["details"]["declared_workflow_timeout_ms"] == 600_000
      assert rejection["details"]["declared_workflow_timeout_explicit"] == true
      next_actions = rejection["details"]["next_actions"]

      assert "increase_wait_horizon_to_suggested_timeout_ms" in next_actions
      refute "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
      refute "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
      refute "increase_workflow_timeout_to_suggested_timeout_ms" in next_actions

      workflow_runner = fn parent_session_id, workflow_spec, opts ->
        send(test_pid, {:effective_workflow_runtime, workflow_spec, opts})

        assert Enum.any?(read_session_events(ws, parent_session_id), fn event ->
                 event["data"] == %{
                   "event" => "horizon_override",
                   "source" => "allow_short_horizon",
                   "scope" => "delegate",
                   "horizon_override" => %{
                     "effective_timeout_ms" => 120_000,
                     "estimated_critical_path_ms" => 240_000,
                     "waves" => 2,
                     "suggested_timeout_ms" => 400_000
                   }
                 }
               end)

        {:ok,
         %{
           "ok" => true,
           "status" => "completed",
           "workflow_id" => "wf_effective_horizon",
           "steps" => [],
           "summary" => %{"steps" => 0}
         }}
      end

      assert {:ok, payload} =
               Runner.run(
                 Map.put(request, :allow_short_horizon?, true),
                 spec,
                 spec_meta,
                 workflow_runner: workflow_runner
               )

      assert payload["horizon_override"] == %{
               "effective_timeout_ms" => 120_000,
               "estimated_critical_path_ms" => 240_000,
               "waves" => 2,
               "suggested_timeout_ms" => 400_000
             }

      assert_received {:effective_workflow_runtime, workflow_spec, opts}
      assert workflow_spec["timeout_ms"] == 120_000
      assert Keyword.fetch!(opts, :timeout_ms) == 120_000
    end)
  end

  test "workflow horizon rejection offers workflow-specific next actions" do
    ws = tmp_workspace("pixir-delegate-workflow-next-actions")

    spec = %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "read_only",
      "timeout_ms" => 120_000,
      "steps" => [
        %{"id" => "first", "task" => "first", "timeout_ms" => 120_000},
        %{
          "id" => "second",
          "task" => "second",
          "depends_on" => ["first"],
          "timeout_ms" => 120_000
        }
      ]
    }

    assert {:error,
            %{
              "details" => %{
                "caller_horizon_ms" => 120_000,
                "declared_workflow_timeout_ms" => 120_000,
                "declared_workflow_timeout_explicit" => true,
                "suggested_timeout_ms" => 240_000
              }
            } = rejection} =
             Runner.admit_horizon(
               %{workspace: ws},
               spec,
               %{"strategy" => "workflow", "planned_child_count" => 2}
             )

    next_actions = rejection["details"]["next_actions"]

    assert "increase_delegate_and_workflow_timeouts_to_suggested_timeout_ms" in next_actions
    refute "increase_delegate_timeout_to_suggested_timeout_ms" in next_actions
    refute "increase_workflow_timeout_to_suggested_timeout_ms" in next_actions
    assert "rerun_with_--allow-short-horizon" in next_actions
    assert Enum.any?(next_actions, &String.contains?(&1, "workflow"))
    refute "reduce_delegate_task_count" in next_actions
    refute "increase_subagents_max_threads" in next_actions
  end

  test "normal Runner start payload omits a nil horizon override" do
    with_pixir_home("pixir-delegate-no-horizon-override-home", fn ->
      ws = tmp_workspace("pixir-delegate-no-horizon-override")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect",
        "limits" => %{"child_timeout_ms" => 1_000, "wait_horizon_ms" => 1_000}
      }

      spawn_agent = fn parent_session_id, _args, _opts ->
        refute Enum.any?(read_session_events(ws, parent_session_id), fn event ->
                 get_in(event, ["data", "event"]) == "horizon_override"
               end)

        {:ok,
         %{
           "id" => "subagent_normal_horizon",
           "agent" => "explorer",
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, %{payload: payload}} =
               Runner.start(
                 %{workspace: ws},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent
               )

      refute Map.has_key?(payload, "horizon_override")

      refute Enum.any?(read_session_events(ws, payload["parent_session_id"]), fn event ->
               get_in(event, ["data", "event"]) == "horizon_override"
             end)
    end)
  end

  test "Runner start payload retains the accepted horizon override values" do
    with_pixir_home("pixir-delegate-horizon-override-home", fn ->
      ws = tmp_workspace("pixir-delegate-horizon-override")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["first", "second"],
        "subagents" => %{"max_threads" => 1},
        "limits" => %{"child_timeout_ms" => 100, "wait_horizon_ms" => 100}
      }

      spawn_agent = fn parent_session_id, args, _opts ->
        override_events =
          Enum.filter(read_session_events(ws, parent_session_id), fn event ->
            get_in(event, ["data", "event"]) == "horizon_override"
          end)

        assert [override_event] = override_events

        assert override_event["data"] == %{
                 "event" => "horizon_override",
                 "source" => "allow_short_horizon",
                 "scope" => "delegate",
                 "horizon_override" => %{
                   "effective_timeout_ms" => 100,
                   "estimated_critical_path_ms" => 200,
                   "waves" => 2,
                   "suggested_timeout_ms" => 200
                 }
               }

        {:ok,
         %{
           "id" => "subagent_#{args["task"]}",
           "agent" => "explorer",
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, %{payload: payload}} =
               Runner.start(
                 %{workspace: ws, allow_short_horizon?: true},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 2},
                 spawn_agent: spawn_agent
               )

      assert payload["horizon_override"] == %{
               "effective_timeout_ms" => 100,
               "estimated_critical_path_ms" => 200,
               "waves" => 2,
               "suggested_timeout_ms" => 200
             }
    end)
  end

  test "bounded_write workflow runtime pairs auto permission mode with the write policy" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-workflow-write")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn parent_session_id, workflow_spec, opts ->
        send(test_pid, {:workflow_runner_called, parent_session_id, workflow_spec, opts})

        {:ok,
         %{
           "ok" => true,
           "status" => "completed",
           "workflow_id" => "wf_runner_test",
           "steps" => [],
           "summary" => %{"steps" => 0}
         }}
      end

      assert {:ok, %{"status" => "completed", "mode" => "bounded_write"}} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert_received {:workflow_runner_called, _parent_session_id, workflow_spec, opts}

      assert Keyword.fetch!(opts, :permission_mode) == :auto
      assert Keyword.fetch!(opts, :write_policy)["id"] == "runner-policy"
      assert Keyword.fetch!(opts, :write_policy)["allow_writes"] == ["notes/out.md"]
      assert get_in(workflow_spec, ["steps", Access.at(0), "write_set"]) == ["notes/out.md"]
    end)
  end

  test "bounded_write workflow failed writer does not report repo mutation success" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-workflow-failed-write")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn parent_session_id, workflow_spec, opts ->
        send(test_pid, {:workflow_runner_called, parent_session_id, workflow_spec, opts})

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_runner_failed_write",
           "steps" => [
             %{
               "step_id" => "write",
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "failed_steps" => [
             %{
               "step_id" => "write",
               "status" => "failed",
               "checkpoint_status" => "failed"
             }
           ],
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "ok" => false,
               "status" => "partial",
               "write_destination" => %{
                 "writes_applied_to" => "indeterminate",
                 "contract_status" => "unverified_partial_writes"
               },
               "children" => [
                 %{
                   "step_id" => "write",
                   "writes_applied_to" => "indeterminate"
                 }
               ]
             } = payload

      refute Map.has_key?(payload["write_destination"], "observed_applied_writes")

      assert_received {:workflow_runner_called, _parent_session_id, workflow_spec, opts}

      assert Keyword.fetch!(opts, :permission_mode) == :auto
      assert Keyword.fetch!(opts, :write_policy)["id"] == "runner-policy"
      assert Keyword.fetch!(opts, :write_policy)["allow_writes"] == ["notes/out.md"]
      assert get_in(workflow_spec, ["steps", Access.at(0), "write_set"]) == ["notes/out.md"]
    end)
  end

  test "bounded_write workflow reports observed partial writes from child log" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-observed-write")
      child_session_id = "20260703T000001-child"

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes then try forbidden write",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_raw_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "tool_call", %{
            "call_id" => "write-ok",
            "name" => "write",
            "args" => %{"path" => "notes/out.md", "content" => "ok"}
          }),
          raw_event(child_session_id, 2, "tool_result", %{
            "call_id" => "write-ok",
            "ok" => true,
            "output" => "wrote 2 bytes to notes/out.md"
          }),
          raw_event(child_session_id, 3, "tool_call", %{
            "call_id" => "write-denied",
            "name" => "write",
            "args" => %{"path" => "secrets/out.md", "content" => "nope"}
          }),
          raw_event(child_session_id, 4, "tool_result", %{
            "call_id" => "write-denied",
            "ok" => false,
            "error" => %{"kind" => "write_policy_denied"}
          })
        ])

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_observed_partial_write",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "writes_applied_to" => "indeterminate",
               "contract_status" => "unverified_partial_writes",
               "observed_applied_writes" => ["notes/out.md"],
               "observed_writes_source" => "child_log",
               "observed_writes_semantics" => "at_least"
             } = payload["write_destination"]

      assert [
               %{
                 "writes_applied_to" => "indeterminate",
                 "observed_applied_writes" => ["notes/out.md"],
                 "observed_writes_source" => "child_log",
                 "observed_writes_semantics" => "at_least"
               }
             ] = payload["children"]
    end)
  end

  test "subagents transport is accepted and surfaced in runtime limits" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-transport")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect transport",
        "subagents" => %{"transport" => "websocket"}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert payload.runtime.provider_transport == "websocket"
      assert get_in(payload.payload, ["limits", "transport"]) == "websocket"
      assert_received {:spawn_agent_called, _parent_session_id, _args, opts}

      assert Keyword.fetch!(Keyword.fetch!(opts, :provider_opts), :provider_transport) ==
               "websocket"

      refute Keyword.has_key?(opts, :provider_transport)
    end)
  end

  test "virtual_overlay spec context threads to child spawn opts" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-virtual-overlay")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "mode" => "read_only",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"],
          "limits" => %{"max_virtual_commands" => 2}
        }
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:virtual_spawn_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_virtual",
           "agent" => "explorer",
           "status" => "queued",
           "summary" => "queued",
           "workspace_mode" => "virtual_overlay"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:virtual_spawn_called, _parent_session_id, args, opts}
      assert args["workspace_mode"] == "virtual_overlay"

      assert Keyword.fetch!(opts, :virtual_overlay) == %{
               read_set: ["mix.exs"],
               limits: %{"max_virtual_commands" => 2}
             }

      assert Keyword.fetch!(opts, :permission_mode) == :read_only
      assert Keyword.fetch!(opts, :write_policy) == nil
    end)
  end

  test "direct Runner validation preserves shared read_set location and reason" do
    ws = tmp_workspace("pixir-delegate-runner-unsafe-read-set")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "produce a virtual diff",
      "mode" => "read_only",
      "subagents" => %{
        "workspace_mode" => "virtual_overlay",
        "read_set" => ["mix.exs", "lib/../**/*"]
      }
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.read_set[2]"
    assert error["details"]["json_pointer"] == "/subagents/read_set/1"
    assert error["details"]["path"] == ["subagents", "read_set", 1]
    assert error["details"]["index"] == 1
    assert error["details"]["reason"] == "parent_component"
  end

  test "virtual child result projects artifact and explicit apply affordance" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-virtual-envelope")

      artifact = %{
        "kind" => "virtual_diff",
        "version" => 1,
        "changes" => [],
        "summary" => %{"diff_bytes" => 0},
        "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true}
      }

      child = %{
        "id" => "subagent_virtual",
        "child_session_id" => "child-session",
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "produce a virtual diff",
        "workspace_mode" => "virtual_overlay",
        "child_log_path" => Path.join(ws, "child.ndjson"),
        "next_actions" => [],
        "virtual_diff" => artifact,
        "virtual_diff_ref" => %{"kind" => "virtual_diff", "encoded_bytes" => 100}
      }

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce a virtual diff",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "complete" => true,
           "counts" => %{
             "completed" => 1,
             "failed" => 0,
             "timed_out" => 0,
             "cancelled" => 0,
             "detached" => 0,
             "incomplete" => 0
           },
           "subagents" => [child],
           "summary" => "completed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert projected["virtual_diff"] == artifact

      assert projected["apply"] == %{
               "status" => "not_applied",
               "requires_explicit_apply" => true,
               "tool" => "apply_virtual_diff",
               "dry_run_default" => true,
               "workflow_apply_from_compatible" => false
             }
    end)
  end

  test "failed virtual child projects preserved artifact and strategy-aware recovery" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-failed-virtual-envelope")

      artifact = %{
        "kind" => "virtual_diff",
        "version" => 1,
        "changes" => [],
        "summary" => %{"diff_bytes" => 0},
        "apply" => %{"status" => "not_applied", "requires_explicit_apply" => true}
      }

      ref = %{"kind" => "virtual_diff", "encoded_bytes" => 100, "source_seq" => 4}

      child = %{
        "id" => "subagent_virtual_failed",
        "child_session_id" => "failed-child-session",
        "agent" => "explorer",
        "status" => "failed",
        "summary" => "provider transport failed after artifact export",
        "task" => "produce then fail",
        "workspace_mode" => "virtual_overlay",
        "child_log_path" => Path.join(ws, "failed-child.ndjson"),
        "next_actions" => ["inspect_child_session_log"],
        "virtual_diff" => artifact,
        "virtual_diff_ref" => ref
      }

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "produce then fail",
        "subagents" => %{
          "workspace_mode" => "virtual_overlay",
          "read_set" => ["mix.exs"]
        }
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "partial",
           "complete" => false,
           "counts" => %{"completed" => 0, "failed" => 1},
           "subagents" => [child],
           "summary" => "failed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 spec,
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert projected["status"] == "failed"
      assert projected["virtual_diff"] == artifact
      assert projected["virtual_diff_ref"] == ref
      assert projected["apply"]["tool"] == "apply_virtual_diff"
      assert projected["recovery"]["virtual_diff_preserved"] == true
      assert projected["recovery"]["virtual_diff_ref"] == ref
      assert projected["recovery"]["apply_is_separate_explicit_decision"] == true

      assert Enum.any?(projected["recovery"]["notes"], &String.contains?(&1, "no longer exists"))

      assert Enum.any?(
               projected["recovery"]["notes"],
               &String.contains?(&1, "Inspect the child Log")
             )
    end)
  end

  test "non-virtual child result does not gain virtual artifact keys" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-shared-envelope")

      child = %{
        "id" => "subagent_shared",
        "child_session_id" => "child-session",
        "agent" => "explorer",
        "status" => "completed",
        "summary" => "done",
        "task" => "inspect",
        "workspace_mode" => "shared",
        "child_log_path" => Path.join(ws, "child.ndjson"),
        "next_actions" => []
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, child} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "counts" => %{"completed" => 1},
           "subagents" => [child],
           "summary" => "completed"
         }}
      end

      assert {:ok, %{"children" => [projected]}} =
               Runner.run(
                 %{workspace: ws},
                 %{"strategy" => "subagents", "task" => "inspect"},
                 %{"strategy" => "subagents", "planned_child_count" => 1},
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      refute Map.has_key?(projected, "virtual_diff")
      refute Map.has_key?(projected, "virtual_diff_ref")
      refute Map.has_key?(projected, "apply")
    end)
  end

  test "subagent provider knobs are threaded to child spawn args and opts" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-provider-knobs")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect model knobs",
        "subagents" => %{"model" => "gpt-5.5", "reasoning_effort" => "high"}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}
      assert args["model"] == "gpt-5.5"
      assert args["reasoning_effort"] == "high"
    end)
  end

  test "subagents web_search threads from spec to child spawn args" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-web-search")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect web_search knob",
        "subagents" => %{"web_search" => true}
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}
      assert args["web_search"] == true

      # Absent knob stays absent: no implicit enablement in the spawn args.
      spec_off = Map.delete(spec, "subagents")

      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec_off, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args_off, _opts}
      refute Map.has_key?(args_off, "web_search")
    end)
  end

  test "subagent task object attachments are normalized into child spawn args" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-attachments")
      File.write!(Path.join(ws, "note.txt"), "evidence")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [%{"task" => "inspect note", "attachments" => ["note.txt"]}]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      refute Map.has_key?(payload.payload, "attachments")

      refute Enum.any?(Map.get(payload.payload, "children", []), fn child ->
               Map.has_key?(child, "attachments") or Map.has_key?(child, "uris") or
                 Map.has_key?(child, "uri")
             end)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}

      assert [%{"type" => "resource_link", "uri" => uri, "name" => "note.txt"}] =
               args["attachments"]

      # Plain path: the encoded URI must equal the literal file:// form.
      assert uri == "file://" <> Path.join(ws, "note.txt")
    end)
  end

  test "attachments outside the workspace are accepted as operator-supplied (ADR 0021)" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-outside")
      outside = tmp_workspace("pixir-delegate-runner-outside-src")
      File.write!(Path.join(outside, "external.txt"), "outside evidence")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [
          %{"task" => "read external", "attachments" => [Path.join(outside, "external.txt")]}
        ]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      # ADR 0021: operator-supplied file:// links are deliberately exempt from
      # workspace read confinement (the spec author is the operator; the
      # model-authored channel is closed by the spawn_agent strip). This test
      # pins that decision so it cannot be re-read as an oversight.
      assert {:ok, _payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert_received {:spawn_agent_called, _parent_session_id, args, _opts}

      assert [%{"type" => "resource_link", "uri" => uri}] = args["attachments"]
      assert uri == "file://" <> Path.join(outside, "external.txt")
    end)
  end

  test "subagent task object attachments reject invalid shapes" do
    ws = tmp_workspace("pixir-delegate-runner-bad-attachments")
    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    cases = [
      {%{"task" => "valid", "unexpected" => true}, "/tasks/0"},
      {%{"task" => 123, "extra" => true}, "/tasks/0"},
      {%{"task" => "valid", "attachments" => nil}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => "note.txt"}, "/tasks/0/attachments"},
      {%{"task" => "valid", "attachments" => [""]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => [123]}, "/tasks/0/attachments/0"},
      {%{"task" => "valid", "attachments" => ["file://evidence.txt"]}, "/tasks/0/attachments/0"}
    ]

    for {entry, pointer} <- cases do
      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => [entry]
      }

      assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
      assert error["kind"] == "invalid_spec"
      assert error["details"]["json_pointer"] == pointer
    end
  end

  test "subagents transport rejects unsupported values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-transport")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect transport",
      "subagents" => %{"transport" => "stdio"}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.transport"
    assert error["details"]["accepted_values"] == ["auto", "websocket", "http_sse"]
  end

  test "subagents model rejects non-string values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-model")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect model",
      "subagents" => %{"model" => 123}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.model"
  end

  test "subagents reasoning_effort rejects unsupported values" do
    ws = tmp_workspace("pixir-delegate-runner-bad-effort")

    spec = %{
      "contract_version" => 1,
      "strategy" => "subagents",
      "task" => "inspect effort",
      "subagents" => %{"reasoning_effort" => "ultra"}
    }

    spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

    assert {:error, error} = Runner.start(%{workspace: ws}, spec, spec_meta)
    assert error["kind"] == "invalid_spec"
    assert error["details"]["field"] == "subagents.reasoning_effort"
    assert error["details"]["accepted_values"] == ["low", "medium", "high", "xhigh", "max"]
  end

  test "bounded_write workflow does not infer observed writes from corrupt child log" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-corrupt-child-log")
      child_session_id = "20260703T000002-child"

      spec = %{
        "contract_version" => 1,
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "metadata" => %{"id" => "runner-policy"},
          "allow_writes" => ["notes/out.md"]
        },
        "steps" => [
          %{
            "id" => "write",
            "task" => "write notes then produce corrupt evidence",
            "agent" => "worker",
            "workspace_mode" => "shared",
            "write_set" => ["notes/out.md"]
          }
        ]
      }

      spec_meta = %{
        "strategy" => "workflow",
        "mode" => "bounded_write",
        "write_policy" => %{
          "version" => 1,
          "id" => "runner-policy",
          "allow_writes" => ["notes/out.md"],
          "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
          "bash" => "disabled"
        },
        "planned_child_count" => 1
      }

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_corrupt_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "tool_call", %{
            "call_id" => "write-ok",
            "name" => "write",
            "args" => %{"path" => "notes/out.md", "content" => "ok"}
          }),
          raw_event(child_session_id, 2, "tool_result", %{
            "call_id" => "write-ok",
            "ok" => true,
            "output" => "wrote 2 bytes to notes/out.md"
          })
        ])

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_corrupt_child_log",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["inspect_delegate_diagnostics"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta, workflow_runner: workflow_runner)

      assert %{
               "writes_applied_to" => "indeterminate",
               "contract_status" => "unverified_partial_writes"
             } = payload["write_destination"]

      refute Map.has_key?(payload["write_destination"], "observed_applied_writes")
      refute Map.has_key?(hd(payload["children"]), "observed_applied_writes")
    end)
  end

  test "subagent runtime assigns task indexes to spawned children and envelopes" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-indexes")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["alpha", "beta"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn _parent_session_id, args, opts ->
        index = Keyword.get(opts, :index)
        send(test_pid, {:spawn_args, args, index})

        {:ok,
         %{
           "id" => "subagent_#{index}",
           "index" => index,
           "agent" => args["agent"],
           "task" => args["task"],
           "status" => "completed",
           "summary" => "done",
           "child_session_id" => "child-#{index}"
         }}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "completed",
           "summary" => "done",
           "counts" => %{"completed" => 2},
           "subagents" => [
             %{
               "id" => "subagent_0",
               "index" => 0,
               "agent" => "default",
               "task" => "alpha",
               "status" => "completed",
               "summary" => "done",
               "child_session_id" => "child-0"
             },
             %{
               "id" => "subagent_1",
               "index" => 1,
               "agent" => "default",
               "task" => "beta",
               "status" => "completed",
               "summary" => "done",
               "child_session_id" => "child-1"
             }
           ]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert_received {:spawn_args, %{"task" => "alpha"} = alpha_args, 0}
      assert_received {:spawn_args, %{"task" => "beta"} = beta_args, 1}
      refute Map.has_key?(alpha_args, "index")
      refute Map.has_key?(beta_args, "index")
      assert Enum.map(payload["children"], & &1["index"]) == [0, 1]
    end)
  end

  test "partial spawn preserves indexes for children already spawned" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-partial-indexes")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["first", "second"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 2}

      spawn_agent = fn
        _parent_session_id, %{"task" => "first"} = args, opts ->
          assert Keyword.get(opts, :index) == 0

          {:ok,
           %{
             "id" => "subagent_0",
             "index" => Keyword.get(opts, :index),
             "agent" => args["agent"],
             "task" => args["task"],
             "status" => "running",
             "summary" => "running",
             "child_session_id" => "child-0"
           }}

        _parent_session_id, %{"task" => "second"}, opts when is_list(opts) ->
          assert Keyword.get(opts, :index) == 1

          # contract-shaped error: normalize_error/1 passes %{"ok" => false}
          # maps through untouched; a bare map would be wrapped as
          # runtime_error and hide the original kind
          {:error,
           %{
             "ok" => false,
             "status" => "rejected",
             "kind" => "spawn_failed",
             "message" => "boom",
             "details" => %{}
           }}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "one running",
           "counts" => %{"incomplete" => 1},
           "subagents" => [
             %{
               "id" => "subagent_0",
               "index" => 0,
               "agent" => "default",
               "task" => "first",
               "status" => "running",
               "summary" => "running",
               "child_session_id" => "child-0"
             }
           ]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert payload["status"] == "partial"
      assert [%{"index" => 0, "task" => "first"}] = payload["children"]
      assert payload["spawn_failure"]["kind"] == "spawn_failed"
    end)
  end

  test "running-at-horizon children keep their task index" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-horizon-indexes")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["keeps running"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      running = %{
        "id" => "subagent_0",
        "index" => 0,
        "agent" => "worker",
        "task" => "keeps running",
        "status" => "running",
        "summary" => "still running",
        "child_session_id" => "child-running"
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, running} end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "horizon reached",
           "counts" => %{"incomplete" => 1},
           "subagents" => [running]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      assert payload["status"] == "timed_out"
      assert [%{"index" => 0, "status" => "running"}] = payload["children"]
    end)
  end

  test "subagent children without retries keep retry lineage keys omitted" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-retry-lineage")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "no retry child"
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      agent = %{
        "id" => "subagent_1",
        "agent" => "worker",
        "status" => "completed",
        "summary" => "done",
        "child_session_id" => "20260706T000000-child"
      }

      spawn_agent = fn _parent_session_id, _args, _opts -> {:ok, agent} end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert [child] = payload.payload["children"]
      refute Map.has_key?(child, "retry_attempts")
      refute Map.has_key?(child, "retry_max_attempts")
      refute Map.has_key?(child, "current_attempt_index")
      refute Map.has_key?(child, "retry_history")
      refute Map.has_key?(child, "resume_command")
      refute Map.has_key?(child, "diagnose_command")
    end)
  end

  test "non-completed terminal children carry ready-made recovery commands" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-child-recovery")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["times out", "fails", "completes", "still running"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 4}

      agents = %{
        "times out" => %{
          "id" => "subagent_1",
          "agent" => "worker",
          "status" => "timed_out",
          "summary" => "",
          "child_session_id" => "20260706T000000-timeout"
        },
        "fails" => %{
          "id" => "subagent_2",
          "agent" => "worker",
          "status" => "failed",
          "summary" => "",
          "child_session_id" => "20260706T000000-failed"
        },
        "completes" => %{
          "id" => "subagent_3",
          "agent" => "worker",
          "status" => "completed",
          "summary" => "done",
          "child_session_id" => "20260706T000000-done"
        },
        "still running" => %{
          "id" => "subagent_4",
          "agent" => "worker",
          "status" => "running",
          "summary" => "",
          "child_session_id" => "20260706T000000-running"
        }
      }

      spawn_agent = fn _parent_session_id, args, _opts ->
        {:ok, Map.fetch!(agents, args["task"])}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      children = payload.payload["children"]
      by_sid = Map.new(children, &{&1["child_session_id"], &1})

      timed_out = by_sid["20260706T000000-timeout"]

      assert timed_out["resume_command"] ==
               ~s(pixir resume 20260706T000000-timeout ) <>
                 ~s("Continue from the latest incomplete turn. Inspect the Log first, ) <>
                 ~s(avoid duplicating completed writes, and report what you resumed.")

      assert timed_out["diagnose_command"] ==
               "pixir diagnose session 20260706T000000-timeout --json"

      failed = by_sid["20260706T000000-failed"]

      assert failed["resume_command"] ==
               ~s(pixir resume 20260706T000000-failed ) <>
                 ~s("Continue from the latest incomplete turn. Inspect the Log first, ) <>
                 ~s(avoid duplicating completed writes, and report what you resumed.")

      assert failed["diagnose_command"] ==
               "pixir diagnose session 20260706T000000-failed --json"

      # This is a start snapshot (kind delegate_start): a running child here is
      # alive and owned, so it must NOT carry recovery commands. The final
      # delegate_result envelope is where running-at-collection-horizon children
      # gain them (functional coverage: the forced-partial dogfood run).
      running = by_sid["20260706T000000-running"]
      refute Map.has_key?(running, "resume_command")
      refute Map.has_key?(running, "diagnose_command")

      completed = by_sid["20260706T000000-done"]
      refute Map.has_key?(completed, "resume_command")
      refute Map.has_key?(completed, "diagnose_command")
    end)
  end

  @safe_resume_prompt "Continue from the latest incomplete turn. Inspect the Log first, " <>
                        "avoid duplicating completed writes, and report what you resumed."

  test "final delegate_result gives recovery commands to children cut off at the horizon" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-horizon-recovery")

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "tasks" => ["keeps running", "gets cancelled", "completes"]
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 3}

      running_with_retry = %{
        "id" => "subagent_1",
        "agent" => "worker",
        "status" => "running",
        "summary" => "",
        "child_session_id" => "20260706T000001-running",
        "retry_attempts" => 1,
        "retry_max_attempts" => 1,
        "current_attempt_index" => 1,
        "retry_history" => [
          %{"attempt_index" => 0, "error_kind" => "websocket_read_failed"}
        ]
      }

      cancelled = %{
        "id" => "subagent_2",
        "agent" => "worker",
        "status" => "cancelled",
        "summary" => "",
        "child_session_id" => "20260706T000001-cancelled"
      }

      completed = %{
        "id" => "subagent_3",
        "agent" => "worker",
        "status" => "completed",
        "summary" => "done",
        "child_session_id" => "20260706T000001-done"
      }

      agents = %{
        "keeps running" => running_with_retry,
        "gets cancelled" => cancelled,
        "completes" => completed
      }

      spawn_agent = fn _parent_session_id, args, _opts ->
        {:ok, Map.fetch!(agents, args["task"])}
      end

      wait_outcome = fn _parent_session_id, _ids, _timeout_ms, _opts ->
        {:ok,
         %{
           "status" => "incomplete",
           "summary" => "horizon reached",
           "counts" => %{"completed" => 1, "cancelled" => 1},
           "subagents" => [running_with_retry, cancelled, completed]
         }}
      end

      assert {:ok, payload} =
               Runner.run(%{workspace: ws}, spec, spec_meta,
                 spawn_agent: spawn_agent,
                 wait_outcome: wait_outcome
               )

      # work_complete is stamped later by CLIContract; at Runner level the
      # incomplete outcome shows as status timed_out with ok false.
      assert payload["kind"] == "delegate_result"
      assert payload["ok"] == false
      assert payload["status"] == "timed_out"

      by_sid = Map.new(payload["children"], &{&1["child_session_id"], &1})

      running = by_sid["20260706T000001-running"]

      assert running["resume_command"] ==
               ~s(pixir resume 20260706T000001-running "#{@safe_resume_prompt}")

      assert running["diagnose_command"] ==
               "pixir diagnose session 20260706T000001-running --json"

      # Retry lineage and recovery commands coexist on the same child.
      assert running["retry_attempts"] == 1
      assert [%{"error_kind" => "websocket_read_failed"}] = running["retry_history"]

      cancelled_child = by_sid["20260706T000001-cancelled"]

      assert cancelled_child["resume_command"] ==
               ~s(pixir resume 20260706T000001-cancelled "#{@safe_resume_prompt}")

      assert cancelled_child["diagnose_command"] ==
               "pixir diagnose session 20260706T000001-cancelled --json"

      completed_child = by_sid["20260706T000001-done"]
      refute Map.has_key?(completed_child, "resume_command")
      refute Map.has_key?(completed_child, "diagnose_command")
    end)
  end

  test "request timeout changes only the caller horizon for omitted and legacy child budgets" do
    request = %{timeout_ms: 360_000}

    omitted_spec = %{
      "strategy" => "subagents",
      "tasks" => ["first", "second", "third"],
      "subagents" => %{"max_threads" => 1}
    }

    assert {:ok,
            %{
              child_timeout_ms: 120_000,
              delegate_timeout_ms: 360_000,
              wait_horizon_ms: 360_000
            }} = Runner.resolve_limits(request, omitted_spec)

    legacy_spec = put_in(omitted_spec, ["limits"], %{"timeout_ms" => 60_000})

    assert {:ok,
            %{
              child_timeout_ms: 60_000,
              delegate_timeout_ms: 360_000,
              wait_horizon_ms: 360_000
            }} = Runner.resolve_limits(request, legacy_spec)
  end

  test "subagents transport is nil when absent" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-transport")
      test_pid = self()

      spec = %{
        "contract_version" => 1,
        "strategy" => "subagents",
        "task" => "inspect default transport"
      }

      spec_meta = %{"strategy" => "subagents", "planned_child_count" => 1}

      spawn_agent = fn parent_session_id, args, opts ->
        send(test_pid, {:spawn_agent_called, parent_session_id, args, opts})

        {:ok,
         %{
           "id" => "subagent_1",
           "agent" => args["agent"] || args[:agent],
           "status" => "queued",
           "summary" => "queued"
         }}
      end

      assert {:ok, payload} =
               Runner.start(%{workspace: ws}, spec, spec_meta, spawn_agent: spawn_agent)

      assert get_in(payload, ["limits", "transport"]) == nil
      assert_received {:spawn_agent_called, _parent_session_id, _args, opts}
      refute Keyword.has_key?(opts, :provider_transport)
    end)
  end

  # ── write_denials confession (#446) ────────────────────────────────────────

  defp bounded_write_denial_events(child_session_id) do
    [
      raw_event(child_session_id, 1, "tool_call", %{
        "call_id" => "write-denied",
        "name" => "write",
        "args" => %{"path" => "secrets/out.md", "content" => "nope"}
      }),
      raw_event(child_session_id, 2, "permission_decision", %{
        "call_id" => "write-denied",
        "decision" => "deny",
        "gate" => "write_policy",
        "tool" => "write",
        "requested_path" => "secrets/out.md",
        "normalized_path" => "secrets/out.md",
        "matched_rule" => "no_allow_match",
        "rule" => "no_allow_match",
        "policy_id" => "runner-policy",
        "policy_hash" => "sha256:deadbeef",
        "policy_version" => 1
      }),
      raw_event(child_session_id, 3, "tool_result", %{
        "call_id" => "write-denied",
        "ok" => false,
        "error" => %{"kind" => "write_policy_denied"}
      }),
      raw_event(child_session_id, 4, "tool_call", %{
        "call_id" => "write-ok",
        "name" => "write",
        "args" => %{"path" => "notes/out.md", "content" => "ok"}
      }),
      raw_event(child_session_id, 5, "tool_result", %{
        "call_id" => "write-ok",
        "ok" => true,
        "output" => "wrote 2 bytes to notes/out.md"
      }),
      # The Turn's terminal event. Without it the Log does not say the worker
      # survived the denial, and the confession honestly reads "unresolved".
      raw_event(child_session_id, 6, "assistant_message", %{
        "text" => "wrote notes/out.md after the denial"
      })
    ]
  end

  defp bounded_write_workflow_spec do
    %{
      "contract_version" => 1,
      "strategy" => "workflow",
      "mode" => "bounded_write",
      "write_policy" => %{
        "version" => 1,
        "metadata" => %{"id" => "runner-policy"},
        "allow_writes" => ["notes/out.md"]
      },
      "steps" => [
        %{
          "id" => "write",
          "task" => "write notes",
          "agent" => "worker",
          "workspace_mode" => "shared",
          "write_set" => ["notes/out.md"]
        }
      ]
    }
  end

  defp bounded_write_spec_meta do
    %{
      "strategy" => "workflow",
      "mode" => "bounded_write",
      "write_policy" => %{
        "version" => 1,
        "id" => "runner-policy",
        "allow_writes" => ["notes/out.md"],
        "deny_writes" => [".pixir/**", ".git/**", "**/.env*", "**/secrets/**"],
        "bash" => "disabled"
      },
      "planned_child_count" => 1
    }
  end

  test "bounded_write envelope confesses a recovered denial alongside a completed status" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-write-denials")
      child_session_id = "20260731T000001-child"

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_raw_session_log(ws, child_session_id, bounded_write_denial_events(child_session_id))

        {:ok,
         %{
           "ok" => true,
           "status" => "completed",
           "workflow_id" => "wf_write_denials",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "completed",
               "subagent_status" => "completed",
               "checkpoint_status" => "checkpoint_ready",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1},
           "safe_next_actions" => []
         }}
      end

      opts = [workflow_runner: workflow_runner]

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 bounded_write_workflow_spec(),
                 bounded_write_spec_meta(),
                 opts
               )

      # A completed run and a non-empty confession coexist in one envelope.
      assert payload["status"] == "completed"

      confession = payload["write_denials"]
      assert confession, "the envelope must always carry write_denials for a bounded-write run"
      assert confession["count"] == 1

      assert [denial] = confession["denials"]
      assert denial["tool"] == "write"
      assert denial["normalized_path"] == "secrets/out.md"
      assert denial["matched_rule"] == "no_allow_match"
      assert denial["disposition"] == "recovered"

      assert [child] = payload["children"]
      assert child["write_denials"]["count"] == 1
      assert [child_denial] = child["write_denials"]["denials"]
      assert child_denial["disposition"] == "recovered"
    end)
  end

  test "bounded_write envelope carries an empty write_denials when nothing was denied" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-denials")
      child_session_id = "20260731T000002-child"

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_raw_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "tool_call", %{
            "call_id" => "write-ok",
            "name" => "write",
            "args" => %{"path" => "notes/out.md", "content" => "ok"}
          }),
          raw_event(child_session_id, 2, "tool_result", %{
            "call_id" => "write-ok",
            "ok" => true,
            "output" => "wrote 2 bytes to notes/out.md"
          })
        ])

        {:ok,
         %{
           "ok" => true,
           "status" => "completed",
           "workflow_id" => "wf_no_denials",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "completed",
               "subagent_status" => "completed",
               "checkpoint_status" => "checkpoint_ready",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1},
           "safe_next_actions" => []
         }}
      end

      opts = [workflow_runner: workflow_runner]

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 bounded_write_workflow_spec(),
                 bounded_write_spec_meta(),
                 opts
               )

      # Present with a zero value: absence is a schema violation, not silence.
      assert payload["write_denials"] == %{"count" => 0, "denials" => []}
      assert [child] = payload["children"]
      assert child["write_denials"] == %{"count" => 0, "denials" => []}
    end)
  end

  test "a bounded_write envelope with no steps still carries write_denials" do
    # The confession must not vanish on the paths that produce no children: a
    # workflow that failed before any step ran is exactly when a coordinator
    # reads the envelope, and an omitted key would read as "no denials" only by
    # convention. Absence is a schema violation, so it must be structurally
    # impossible on a terminal bounded-write envelope.
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-no-steps")

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        {:ok,
         %{
           "ok" => false,
           "status" => "failed",
           "workflow_id" => "wf_no_steps",
           "steps" => [],
           "summary" => %{"steps" => 0},
           "safe_next_actions" => []
         }}
      end

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 bounded_write_workflow_spec(),
                 bounded_write_spec_meta(),
                 workflow_runner: workflow_runner
               )

      assert payload["write_denials"] == %{"count" => 0, "denials" => []}
    end)
  end

  test "a fatal second denial is confessed as the fatal strike" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-fatal-denial")
      child_session_id = "20260731T000003-child"

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        write_raw_session_log(ws, child_session_id, [
          raw_event(child_session_id, 1, "permission_decision", %{
            "call_id" => "d1",
            "decision" => "deny",
            "gate" => "write_policy",
            "tool" => "write",
            "normalized_path" => "secrets/a.md",
            "matched_rule" => "no_allow_match",
            "policy_id" => "runner-policy"
          }),
          raw_event(child_session_id, 2, "permission_decision", %{
            "call_id" => "d2",
            "decision" => "deny",
            "gate" => "write_policy",
            "tool" => "edit",
            "normalized_path" => "secrets/b.md",
            "matched_rule" => "no_allow_match",
            "policy_id" => "runner-policy"
          }),
          raw_event(child_session_id, 3, "turn_failed", %{
            "terminal_status" => "tool_error",
            "error_kind" => "write_policy_denied"
          })
        ])

        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_fatal_denial",
           "steps" => [
             %{
               "step_id" => "write",
               "child_session_id" => child_session_id,
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      opts = [workflow_runner: workflow_runner]

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 bounded_write_workflow_spec(),
                 bounded_write_spec_meta(),
                 opts
               )

      assert payload["write_denials"]["count"] == 2
      assert [first, second] = payload["write_denials"]["denials"]
      assert first["disposition"] == "recovered"
      assert second["disposition"] == "fatal"
      assert second["tool"] == "edit"
    end)
  end

  # Unavailability has to reach the top of the envelope. A coordinator that sums
  # the aggregate `count` must not be handed a total that silently counts an
  # unreadable child's Log as zero denials: the aggregate withholds the total and
  # names the reason instead.
  test "a child whose Log cannot be read makes the aggregate confession unavailable" do
    with_pixir_home("pixir-delegate-runner-home", fn ->
      ws = tmp_workspace("pixir-delegate-runner-unreadable-log")

      workflow_runner = fn _parent_session_id, _workflow_spec, _opts ->
        {:ok,
         %{
           "ok" => false,
           "status" => "partial",
           "workflow_id" => "wf_unreadable_log",
           "steps" => [
             %{
               "step_id" => "write",
               # An id the Log refuses outright: the evidence cannot be read.
               "child_session_id" => "../../etc/passwd",
               "status" => "failed",
               "subagent_status" => "failed",
               "checkpoint_status" => "failed",
               "workspace_mode" => "shared",
               "write_set" => ["notes/out.md"]
             }
           ],
           "summary" => %{"steps" => 1, "failed_steps" => 1},
           "safe_next_actions" => ["retry_failed_steps"]
         }}
      end

      assert {:ok, payload} =
               Runner.run(
                 %{workspace: ws},
                 bounded_write_workflow_spec(),
                 bounded_write_spec_meta(),
                 workflow_runner: workflow_runner
               )

      assert payload["write_denials"]["status"] == "unavailable"
      assert payload["write_denials"]["count"] == nil
      assert payload["write_denials"]["denials"] == []
      assert is_binary(payload["write_denials"]["error"])

      assert [child] = payload["children"]
      assert child["write_denials"]["status"] == "unavailable"
    end)
  end
end
