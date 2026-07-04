defmodule Pixir.CompactionTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Compaction, Event, Log}

  @skill_limitation "Skills activated only inside the compacted range are not replayed unless they remain in the recent raw tail or are explicitly re-activated."
  @named_skill_limitation "Compacted skill activations: diagnose (seq 1, .pixir/skills/diagnose/SKILL.md, sha256 deadbeef)."
  @diagnose_activation_record %{
    "seq" => 1,
    "name" => "diagnose",
    "path" => ".pixir/skills/diagnose/SKILL.md",
    "content_hash" => "deadbeef"
  }

  setup do
    ws =
      Path.join(
        System.tmp_dir!(),
        "pixir-compaction-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(ws)
    sid = "sess-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    on_exit(fn ->
      if Process.whereis(Pixir.Sessions.Registry) do
        case Registry.lookup(Pixir.Sessions.Registry, sid) do
          [{pid, _}] -> GenServer.stop(pid)
          [] -> :ok
        end
      end

      File.rm_rf!(ws)
    end)

    %{ws: ws, sid: sid}
  end

  test "dry_run is a no-op when History fits inside requested tail", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two")
    ])

    assert {:ok,
            %{
              "ok" => true,
              "compactable" => false,
              "recorded" => false,
              "tail_events" => 2
            }} = Compaction.dry_run(sid, workspace: ws, tail_events: 5)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.map(history, & &1.type) == [:user_message, :assistant_message]
  end

  test "compact records a durable history_compaction checkpoint", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.tool_call(sid, "call_1", "read_file", %{"path" => "lib/pixir.ex"}),
      Event.tool_result(sid, "call_1", %{"ok" => true, "output" => "ok"}),
      Event.assistant_message(sid, "done")
    ])

    assert {:ok,
            %{
              "ok" => true,
              "compactable" => true,
              "recorded" => true,
              "would_compact_events" => 3,
              "compaction_seq" => 5,
              "event" => %{
                "range" => %{"from_seq" => 0, "to_seq" => 2},
                "source_event_count" => 3,
                "tail_event_count" => 2
              }
            }} = Compaction.compact(sid, workspace: ws, tail_events: 2)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert List.last(history).type == :history_compaction
    assert List.last(history).seq == 5
  end

  test "compact records trigger \"manual\" by default (ADR 0020)", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => %{"trigger" => "manual"}}} =
             Compaction.compact(sid, workspace: ws, tail_events: 1)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert List.last(history).data["trigger"] == "manual"
  end

  test "compact threads an overflow_recovery trigger into the checkpoint", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => %{"trigger" => "overflow_recovery"}}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               trigger: "overflow_recovery"
             )

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert List.last(history).data["trigger"] == "overflow_recovery"
  end

  test "dry_run carries the trigger without mutating the Log", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => false, "event" => %{"trigger" => "manual"}}} =
             Compaction.dry_run(sid, workspace: ws, tail_events: 1)

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :history_compaction))
  end

  test "compact rejects an unknown trigger with a structured error", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:error, %{ok: false, error: %{kind: :invalid_args, details: %{trigger: "auto"}}}} =
             Compaction.compact(sid, workspace: ws, tail_events: 1, trigger: "auto")
  end

  test "latest_checkpoint_to_seq reads the newest checkpoint range", %{sid: sid} do
    assert Compaction.latest_checkpoint_to_seq([]) == nil

    history = [
      Event.user_message(sid, "old") |> Event.with_seq(0),
      Event.history_compaction(sid, %{"range" => %{"from_seq" => 0, "to_seq" => 0}})
      |> Event.with_seq(1),
      Event.user_message(sid, "newer") |> Event.with_seq(2),
      Event.history_compaction(sid, %{"range" => %{"from_seq" => 0, "to_seq" => 2}})
      |> Event.with_seq(3)
    ]

    assert Compaction.latest_checkpoint_to_seq(history) == 2
  end

  test "provider_history keeps latest compaction and uncompressed tail only", %{sid: sid} do
    history = [
      Event.user_message(sid, "old") |> Event.with_seq(0),
      Event.assistant_message(sid, "older") |> Event.with_seq(1),
      Event.history_compaction(sid, %{
        "range" => %{"from_seq" => 0, "to_seq" => 1},
        "summary" => "old summary",
        "strategy" => "deterministic_operational_summary_v1",
        "source_event_count" => 2,
        "tail_event_count" => 1
      })
      |> Event.with_seq(2),
      Event.user_message(sid, "recent") |> Event.with_seq(3)
    ]

    assert [%{type: :history_compaction}, %{type: :user_message, data: %{"text" => "recent"}}] =
             Compaction.provider_history(history)
  end

  test "compact rolls prior checkpoint forward on repeated compaction", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.tool_call(sid, "call_1", "read_file", %{"path" => "lib/pixir.ex"}),
      Event.tool_result(sid, "call_1", %{"ok" => true, "output" => "ok"}),
      Event.assistant_message(sid, "done")
    ])

    assert {:ok,
            %{"recorded" => true, "event" => %{"range" => %{"from_seq" => 0, "to_seq" => 2}}}} =
             Compaction.compact(sid, workspace: ws, tail_events: 2)

    append_event(ws, Event.user_message(sid, "later request") |> Event.with_seq(6))
    append_event(ws, Event.assistant_message(sid, "later answer") |> Event.with_seq(7))
    append_event(ws, Event.user_message(sid, "latest request") |> Event.with_seq(8))

    assert {:ok,
            %{
              "compactable" => true,
              "would_compact_events" => 3,
              "event" => %{
                "range" => %{"from_seq" => 0, "to_seq" => 6},
                "source_event_count" => 6,
                "summary" => summary,
                "open_tasks" => open_tasks
              }
            }} = Compaction.dry_run(sid, workspace: ws, tail_events: 2)

    assert summary =~ "previous checkpoint seq 0..2"
    assert summary =~ "Compacted 3 events"
    assert Enum.any?(open_tasks, &String.contains?(&1, "previous checkpoint seq 0..2"))

    assert {:ok, %{"recorded" => true, "event" => event_data}} =
             Compaction.compact(sid, workspace: ws, tail_events: 2)

    assert event_data["range"] == %{"from_seq" => 0, "to_seq" => 6}
    assert event_data["source_event_count"] == 6

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [
             %{type: :history_compaction, data: %{"range" => %{"from_seq" => 0, "to_seq" => 6}}},
             %{type: :assistant_message, data: %{"text" => "later answer"}},
             %{type: :user_message, data: %{"text" => "latest request"}}
           ] = Compaction.provider_history(history)
  end

  test "dry_run records the skill-activation limitation when activations fall inside the compacted range without mutating the Log",
       %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "use the diagnose skill"),
      skill_activation_event(sid),
      Event.assistant_message(sid, "activated"),
      Event.user_message(sid, "continue"),
      Event.assistant_message(sid, "done")
    ])

    assert {:ok, %{"compactable" => true, "event" => event_data}} =
             Compaction.dry_run(sid, workspace: ws, tail_events: 2)

    assert @skill_limitation in event_data["limitations"]
    assert @named_skill_limitation in event_data["limitations"]
    assert event_data["event_counts"]["skill_activation"] == 1
    assert event_data["compacted_skill_activation_count"] == 1
    assert event_data["compacted_skill_activations"] == [@diagnose_activation_record]
    assert Enum.all?(event_data["limitations"], &is_binary/1)

    rendered = Compaction.render_for_provider(event_data)
    assert rendered =~ @skill_limitation
    assert rendered =~ @named_skill_limitation

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert length(history) == 5
    refute Enum.any?(history, &(&1.type == :history_compaction))
  end

  test "limitation is absent when skill activations live only in the kept tail",
       %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.tool_call(sid, "call_1", "read_file", %{"path" => "lib/pixir.ex"}),
      skill_activation_event(sid),
      Event.user_message(sid, "latest")
    ])

    assert {:ok, %{"compactable" => true, "tail_events" => 2, "event" => event_data}} =
             Compaction.dry_run(sid, workspace: ws, tail_events: 2)

    refute @skill_limitation in event_data["limitations"]
    refute Map.has_key?(event_data["event_counts"], "skill_activation")
    assert event_data["compacted_skill_activation_count"] == 0
    assert event_data["compacted_skill_activations"] == []
    refute Enum.any?(event_data["limitations"], &(&1 =~ "Compacted skill activations:"))
    refute Compaction.render_for_provider(event_data) =~ @skill_limitation
  end

  test "limitation survives repeated compaction through carry-forward checkpoints",
       %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "use the diagnose skill"),
      skill_activation_event(sid),
      Event.assistant_message(sid, "activated"),
      Event.user_message(sid, "continue"),
      Event.assistant_message(sid, "done")
    ])

    assert {:ok, %{"recorded" => true, "compaction_seq" => 5, "event" => first_checkpoint}} =
             Compaction.compact(sid, workspace: ws, tail_events: 2)

    assert @skill_limitation in first_checkpoint["limitations"]
    assert @named_skill_limitation in first_checkpoint["limitations"]
    assert first_checkpoint["event_counts"]["skill_activation"] == 1
    assert first_checkpoint["compacted_skill_activation_count"] == 1
    assert first_checkpoint["compacted_skill_activations"] == [@diagnose_activation_record]

    append_event(ws, Event.user_message(sid, "later request") |> Event.with_seq(6))
    append_event(ws, Event.assistant_message(sid, "later answer") |> Event.with_seq(7))
    append_event(ws, Event.user_message(sid, "latest request") |> Event.with_seq(8))

    assert {:ok,
            %{
              "recorded" => true,
              "event" => %{"range" => %{"from_seq" => 0, "to_seq" => 6}} = second_checkpoint
            }} = Compaction.compact(sid, workspace: ws, tail_events: 2)

    # The raw skill activation Event is gone from the flat counts, but the structural
    # aggregate and the per-activation identities carry forward through the nested
    # checkpoint.
    refute Map.has_key?(second_checkpoint["event_counts"], "skill_activation")
    assert second_checkpoint["event_counts"]["history_compaction"] == 1
    assert second_checkpoint["compacted_skill_activation_count"] == 1
    assert second_checkpoint["compacted_skill_activations"] == [@diagnose_activation_record]
    assert @skill_limitation in second_checkpoint["limitations"]
    assert @named_skill_limitation in second_checkpoint["limitations"]

    append_event(ws, Event.user_message(sid, "even later") |> Event.with_seq(10))
    append_event(ws, Event.assistant_message(sid, "still going") |> Event.with_seq(11))
    append_event(ws, Event.user_message(sid, "newest") |> Event.with_seq(12))

    # Two checkpoints deep: the structural count still proves the drop; the limitation
    # sentence is presentational only.
    assert {:ok, %{"recorded" => true, "event" => third_checkpoint}} =
             Compaction.compact(sid, workspace: ws, tail_events: 2)

    assert third_checkpoint["compacted_skill_activation_count"] == 1
    assert third_checkpoint["compacted_skill_activations"] == [@diagnose_activation_record]
    assert @skill_limitation in third_checkpoint["limitations"]
    assert @named_skill_limitation in third_checkpoint["limitations"]

    rendered = Compaction.render_for_provider(third_checkpoint)
    assert rendered =~ @skill_limitation
    assert rendered =~ @named_skill_limitation
  end

  test "re-compaction merges carried-forward identities with newly dropped activations",
       %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "use the diagnose skill"),
      skill_activation_event(sid),
      Event.assistant_message(sid, "activated"),
      Event.user_message(sid, "continue"),
      Event.assistant_message(sid, "done")
    ])

    assert {:ok, %{"recorded" => true}} = Compaction.compact(sid, workspace: ws, tail_events: 2)

    append_event(
      ws,
      Event.skill_activation(sid, %{
        "name" => "verify",
        "description" => "Run the app and observe behavior.",
        "scope" => "project",
        "source" => "workspace",
        "root" => ".pixir/skills/verify",
        "path" => ".pixir/skills/verify/SKILL.md",
        "short_path" => "verify/SKILL.md",
        "content_hash" => "cafef00d",
        "content" => "# Verify\nRun and observe.",
        "activated_by" => "explicit_mention"
      })
      |> Event.with_seq(6)
    )

    append_event(ws, Event.assistant_message(sid, "verified") |> Event.with_seq(7))
    append_event(ws, Event.user_message(sid, "next") |> Event.with_seq(8))

    assert {:ok, %{"recorded" => true, "event" => checkpoint}} =
             Compaction.compact(sid, workspace: ws, tail_events: 2)

    assert checkpoint["compacted_skill_activation_count"] == 2

    assert checkpoint["compacted_skill_activations"] == [
             @diagnose_activation_record,
             %{
               "seq" => 6,
               "name" => "verify",
               "path" => ".pixir/skills/verify/SKILL.md",
               "content_hash" => "cafef00d"
             }
           ]

    named = Enum.find(checkpoint["limitations"], &(&1 =~ "Compacted skill activations:"))
    assert named =~ "diagnose (seq 1, .pixir/skills/diagnose/SKILL.md, sha256 deadbeef)"
    assert named =~ "verify (seq 6, .pixir/skills/verify/SKILL.md, sha256 cafef00d)"
  end

  test "compacted skill activation identities are bounded in persisted checkpoint and limitation",
       %{ws: ws, sid: sid} do
    events =
      Enum.map(1..8, &skill_activation_event(sid, &1)) ++
        [Event.assistant_message(sid, "recent tail")]

    append_history(ws, events)

    assert {:ok, %{"recorded" => true, "event" => checkpoint}} =
             Compaction.compact(sid, workspace: ws, tail_events: 1)

    assert checkpoint["compacted_skill_activation_count"] == 8
    assert length(checkpoint["compacted_skill_activations"]) == 5
    assert hd(checkpoint["compacted_skill_activations"])["name"] == "skill-4"
    assert List.last(checkpoint["compacted_skill_activations"])["name"] == "skill-8"

    named = Enum.find(checkpoint["limitations"], &(&1 =~ "Compacted skill activations:"))
    assert named =~ "skill-4"
    assert named =~ "skill-8"
    assert named =~ "+3 earlier"
    refute named =~ "skill-1"
  end

  test "limitation propagates from a legacy checkpoint that lacks the explicit count",
       %{ws: ws, sid: sid} do
    legacy_checkpoint =
      Event.history_compaction(sid, %{
        "strategy" => "deterministic_operational_summary_v1",
        "range" => %{"from_seq" => 0, "to_seq" => 2},
        "source_event_count" => 3,
        "event_counts" => %{"skill_activation" => 1, "user_message" => 2},
        "limitations" => ["wording predating the canonical statement"],
        "summary" => "legacy checkpoint"
      })

    append_history(ws, [
      Event.user_message(sid, "zero"),
      Event.assistant_message(sid, "one"),
      skill_activation_event(sid),
      legacy_checkpoint,
      Event.user_message(sid, "later request"),
      Event.assistant_message(sid, "later answer"),
      Event.user_message(sid, "latest request")
    ])

    assert {:ok, %{"compactable" => true, "event" => event_data}} =
             Compaction.dry_run(sid, workspace: ws, tail_events: 2)

    assert event_data["compacted_skill_activation_count"] == 1
    assert @skill_limitation in event_data["limitations"]

    # A legacy checkpoint proves the drop happened but never persisted identities, so
    # the canonical sentence fires while the named line stays absent — the raw Log is
    # the recovery path for pre-identity checkpoints.
    assert event_data["compacted_skill_activations"] == []
    refute Enum.any?(event_data["limitations"], &(&1 =~ "Compacted skill activations:"))
  end

  test "render_for_provider exposes summary, range, limitations, and open tasks" do
    text =
      Compaction.render_for_provider(%{
        "range" => %{"from_seq" => 0, "to_seq" => 2},
        "source_event_count" => 3,
        "strategy" => "deterministic_operational_summary_v1",
        "summary" => "Compacted old context.",
        "files_touched" => ["lib/pixir.ex"],
        "open_tasks" => ["user: fix compaction"],
        "limitations" => ["full Log remains authoritative"]
      })

    assert text =~ "Compressed session memory"
    assert text =~ "seq 0..2"
    assert text =~ "Compacted old context."
    assert text =~ "lib/pixir.ex"
    assert text =~ "full Log remains authoritative"
  end

  test "developer_instruction is a concise reasoning-model contract, not a process script" do
    instruction = Compaction.developer_instruction()

    assert instruction =~ "Goal:"
    assert instruction =~ "Constraints:"
    assert instruction =~ "Output:"
    assert instruction =~ "matching the provided JSON schema"
    refute instruction =~ "think step by step"
    refute instruction =~ "chain-of-thought"
    assert String.length(instruction) < 1_400
  end

  test "output_schema is strict and owns the checkpoint shape" do
    schema = Compaction.output_schema()
    root = schema["schema"]

    assert schema["name"] == "pixir_history_compaction_checkpoint"
    assert schema["strict"] == true
    assert root["type"] == "object"
    assert root["additionalProperties"] == false

    assert MapSet.new(root["required"]) == MapSet.new(Map.keys(root["properties"]))
    assert root["properties"]["decisions"]["items"]["additionalProperties"] == false
    assert root["properties"]["commands_and_evidence"]["items"]["additionalProperties"] == false

    assert root["properties"]["subagents_and_workflows"]["items"]["properties"]["status"]["enum"] ==
             [
               "completed",
               "failed",
               "timed_out",
               "cancelled",
               "detached",
               "unknown"
             ]
  end

  test "model_contract returns instruction, schema, and delimited event payload", %{sid: sid} do
    events = [
      Event.user_message(sid, "please continue") |> Event.with_seq(3),
      Event.tool_call(sid, "call_1", "bash", %{"command" => "mix test"}) |> Event.with_seq(4)
    ]

    assert {:ok,
            %{
              "developer_instruction" => instruction,
              "output_schema" => schema,
              "input" => %{
                "compaction_scope" => %{
                  "session_id" => ^sid,
                  "compact_range" => %{"from_seq" => 3, "to_seq" => 4},
                  "tail_policy" => "keep last 7 events outside this checkpoint"
                },
                "events" => [first, second]
              }
            } = contract} = Compaction.model_contract(sid, events, tail_events: 7)

    assert instruction == Compaction.developer_instruction()
    assert schema == Compaction.output_schema()
    assert first["type"] == "user_message"
    assert second["data"]["call_id"] == "call_1"
    assert Jason.encode!(contract)
  end

  test "model_contract returns structured error for empty events", %{sid: sid} do
    assert {:error,
            %{
              ok: false,
              error: %{
                kind: :invalid_args,
                message: "cannot build model contract for empty events",
                details: %{session_id: ^sid, events: []}
              }
            }} = Compaction.model_contract(sid, [])
  end

  test "dry_run reports model-assisted mode without calling Provider", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:ok,
            %{
              "model_assisted" => true,
              "recorded" => false,
              "event" => %{"strategy" => "model_assisted_operational_summary_v1"}
            }} =
             Compaction.dry_run(sid, workspace: ws, tail_events: 1, model_assisted: true)
  end

  test "compact uses model-assisted Provider path and records checkpoint after validation", %{
    ws: ws,
    sid: sid
  } do
    auth = start_auth()

    append_history(ws, [
      Event.user_message(sid, "implement compaction"),
      Event.assistant_message(sid, "working"),
      Event.user_message(sid, "continue")
    ])

    transport = compaction_transport(valid_model_checkpoint())

    assert {:ok,
            %{
              "recorded" => true,
              "model_assisted" => true,
              "event" => %{
                "strategy" => "model_assisted_operational_summary_v1",
                "summary" => summary,
                "model_checkpoint" => %{"summary" => "Model compacted three events."}
              }
            }} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               model_assisted: true,
               auth: auth,
               transport: transport
             )

    assert summary =~ "Model compacted three events."
    assert summary =~ "Current objective: finish compaction tracer"

    assert {:ok, history} = Log.fold(sid, workspace: ws)

    assert [%{type: :history_compaction, data: data}] =
             Enum.filter(history, &(&1.type == :history_compaction))

    assert data["strategy"] == "model_assisted_operational_summary_v1"
    refute Map.get(data, "model_assisted_fallback")
  end

  test "compact falls back to deterministic checkpoint when model output is invalid", %{
    ws: ws,
    sid: sid
  } do
    auth = start_auth()

    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    transport = compaction_transport(%{"summary" => "missing required fields"})

    assert {:ok, %{"recorded" => true, "event" => event}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               model_assisted: true,
               auth: auth,
               transport: transport
             )

    assert event["strategy"] == "deterministic_operational_summary_v1"
    assert event["model_assisted_fallback"] == true
    assert event["model_assisted_fallback_reason"] == "invalid_response"
  end

  test "compact falls back to deterministic checkpoint when Provider fails", %{ws: ws, sid: sid} do
    auth = start_auth()

    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    transport = fn _request, _acc, _fun ->
      {:error, %{error: %{kind: :network, message: "down", details: %{}}}}
    end

    assert {:ok, %{"recorded" => true, "event" => event}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               model_assisted: true,
               auth: auth,
               transport: transport
             )

    assert event["strategy"] == "deterministic_operational_summary_v1"
    assert event["model_assisted_fallback"] == true
    assert event["model_assisted_fallback_reason"] == "network"
  end

  test "validate_model_checkpoint rejects missing required fields" do
    assert {:error, %{error: %{kind: :invalid_response, details: %{missing: _}}}} =
             Compaction.validate_model_checkpoint(%{"summary" => "only summary"})
  end

  defp start_auth do
    name = :"auth_#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-compaction-auth-#{System.unique_integer([:positive])}.json"
      )

    {:ok, _} =
      Auth.start_link(
        name: name,
        store_path: path,
        env_api_key: "sk-test",
        oauth: __MODULE__.NoOAuth
      )

    on_exit(fn -> File.rm_rf!(path) end)
    name
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defp compaction_transport(checkpoint) do
    chunks = [
      "data: " <>
        Jason.encode!(%{type: "response.output_text.delta", delta: Jason.encode!(checkpoint)}) <>
        "\n\n",
      "data: " <> Jason.encode!(%{type: "response.completed"}) <> "\n\n"
    ]

    fn _http_request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)}
    end
  end

  defp valid_model_checkpoint do
    %{
      "summary" => "Model compacted three events.",
      "current_objective" => "finish compaction tracer",
      "user_instructions" => ["keep tests offline"],
      "decisions" => [
        %{
          "seq" => 1,
          "decision" => "use Provider stub",
          "rationale" => "no network in tests",
          "status" => "accepted"
        }
      ],
      "work_completed" => ["wired model-assisted compaction"],
      "open_tasks" => ["open PR"],
      "files_touched" => ["lib/pixir/compaction.ex"],
      "commands_and_evidence" => [
        %{
          "seq" => 2,
          "command_or_tool" => "mix test",
          "result" => "passed",
          "important_output" => "compaction tests green"
        }
      ],
      "subagents_and_workflows" => [
        %{"id" => "none", "status" => "unknown", "result" => "none", "usable" => false}
      ],
      "risks" => [],
      "open_questions" => [],
      "limitations" => ["Model-assisted checkpoint; full Log remains authoritative."]
    }
  end

  defp skill_activation_event(sid) do
    Event.skill_activation(sid, %{
      "name" => "diagnose",
      "description" => "Disciplined diagnosis loop for hard bugs.",
      "scope" => "project",
      "source" => "workspace",
      "root" => ".pixir/skills/diagnose",
      "path" => ".pixir/skills/diagnose/SKILL.md",
      "short_path" => "diagnose/SKILL.md",
      "content_hash" => "deadbeef",
      "content" => "# Diagnose\nReproduce, minimise, hypothesise, fix.",
      "activated_by" => "explicit_mention"
    })
  end

  defp skill_activation_event(sid, index) do
    Event.skill_activation(sid, %{
      "name" => "skill-#{index}",
      "description" => "Generated test skill #{index}.",
      "scope" => "project",
      "source" => "workspace",
      "root" => ".pixir/skills/skill-#{index}",
      "path" => ".pixir/skills/skill-#{index}/SKILL.md",
      "short_path" => "skill-#{index}/SKILL.md",
      "content_hash" => "hash-#{index}",
      "content" => "# Skill #{index}\nTest.",
      "activated_by" => "explicit_mention"
    })
  end

  defp append_history(ws, events) do
    events
    |> Enum.with_index()
    |> Enum.each(fn {event, seq} ->
      stop_session_if_alive(event.session_id)
      assert {:ok, _path} = Log.append(Event.with_seq(event, seq), workspace: ws)
    end)
  end

  defp append_event(ws, event) do
    stop_session_if_alive(event.session_id)
    assert {:ok, _path} = Log.append(event, workspace: ws)
  end

  defp stop_session_if_alive(session_id) do
    if Process.whereis(Pixir.Sessions.Registry) do
      case Registry.lookup(Pixir.Sessions.Registry, session_id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end
    else
      :ok
    end
  end
end
