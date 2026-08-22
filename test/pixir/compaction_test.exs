defmodule Pixir.CompactionTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Compaction, Event, Log, Provider}

  @skill_limitation "Skills activated only inside the compacted range are not replayed unless they remain in the recent raw tail or are explicitly re-activated."
  @named_skill_limitation "Compacted skill activations: diagnose (seq 1, .pixir/skills/diagnose/SKILL.md, sha256 deadbeef)."
  @diagnose_activation_record %{
    "seq" => 1,
    "name" => "diagnose",
    "path" => ".pixir/skills/diagnose/SKILL.md",
    "content_hash" => "deadbeef"
  }

  setup do
    # #563: plant operator-like ~/.pixir config, then isolate PIXIR_HOME so
    # overlay/model assertions cannot inherit the real operator home.
    Pixir.Test.OperatorState.isolate_pixir_home!()

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

  test "complete returns a structured recorded result without fabricating pressure", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.assistant_message(sid, "three")
    ])

    assert {:ok,
            %{
              "status" => "recorded",
              "range" => %{"from_seq" => 0, "to_seq" => 1},
              "checkpoint" => %{
                "seq" => 3,
                "event_id" => event_id,
                "data" => %{"trigger" => "manual"}
              }
            } = completion} =
             Compaction.complete(sid, workspace: ws, tail_events: 1)

    assert is_binary(event_id)
    refute Map.has_key?(completion, "pressure_snapshot")

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.count(history, &(&1.type == :history_compaction)) == 1
  end

  test "complete returns a structured no-op without a fake checkpoint or pressure", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [Event.user_message(sid, "one")])

    assert {:ok,
            %{
              "status" => "no_op",
              "range" => nil,
              "checkpoint" => nil,
              "reason" => "history does not exceed requested tail"
            } = completion} = Compaction.complete(sid, workspace: ws, tail_events: 1)

    refute Map.has_key?(completion, "pressure_snapshot")
    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :history_compaction))
  end

  test "complete returns a structured error without a fake checkpoint or pressure", %{
    ws: ws,
    sid: sid
  } do
    assert {:ok,
            %{
              "status" => "error",
              "range" => nil,
              "checkpoint" => nil,
              "error" => %{error: %{kind: :invalid_args}}
            } = completion} = Compaction.complete(sid, workspace: ws, tail_events: 0)

    refute Map.has_key?(completion, "pressure_snapshot")
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

  test "persist_threshold_item writes a singleton cmp_ window with local text", %{sid: sid} do
    local = local_checkpoint_data()
    item = cmp_item("cmp_threshold_ok")

    assert {:ok, data} =
             Compaction.persist_threshold_item(local, item,
               provider: "openai_responses",
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    replay = data["native_replay"]
    assert replay["mode"] == "threshold_item"
    assert replay["recorded_usable"] == true
    refute Map.has_key?(replay, "fallback_reason")
    assert replay["items"] == [item]
    assert replay["compaction_item_ids"] == ["cmp_threshold_ok"]
    assert data["summary"] == local["summary"]
    assert data["range"] == local["range"]
    assert data["strategy"] == local["strategy"]
    assert data["limitations"] == local["limitations"]
    assert Enum.all?(Map.keys(replay), &is_binary/1)

    event = Event.history_compaction(sid, data)
    assert event.type == :history_compaction
    assert event.data["native_replay"]["compaction_item_ids"] == ["cmp_threshold_ok"]
  end

  test "persist_threshold_item rejects a full compact output as threshold_item_not_singleton" do
    output = [
      %{"type" => "message", "role" => "user", "content" => "kept"},
      cmp_item("cmp_not_alone")
    ]

    assert {:error, %{error: %{kind: :threshold_item_not_singleton}}} =
             Compaction.persist_threshold_item(local_checkpoint_data(), output,
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )
  end

  test "validate_native_replay marks standalone_window_pruned when output is reduced to cmp_" do
    cmp = cmp_item("cmp_standalone")
    output = [%{"type" => "message", "role" => "assistant", "content" => "kept"}, cmp]

    replay = %{
      "mode" => "standalone_window",
      "provider" => "openai_responses",
      "backend" => "chatgpt_codex",
      "dialect" => "chatgpt_codex",
      "model" => "gpt-5.5",
      "items" => [cmp]
    }

    assert {:ok,
            %{
              "recorded_usable" => false,
              "fallback_reason" => "standalone_window_pruned"
            }} = Compaction.validate_native_replay(replay, compact_output: output)

    assert {:ok, %{"recorded_usable" => true}} =
             Compaction.validate_native_replay(%{replay | "items" => output},
               compact_output: output
             )
  end

  test "function_call with missing or blank call_id is unpaired" do
    base = %{
      "mode" => "standalone_window",
      "provider" => "openai_responses",
      "backend" => "chatgpt_codex",
      "dialect" => "chatgpt_codex",
      "model" => "gpt-5.5"
    }

    for call <- [
          %{"type" => "function_call", "name" => "read"},
          %{"type" => "function_call", "name" => "read", "call_id" => ""},
          %{"type" => "function_call", "name" => "read", "call_id" => "call_missing_output"}
        ] do
      replay = Map.put(base, "items", [call, cmp_item("cmp_unpaired_validate")])

      assert {:ok,
              %{
                "recorded_usable" => false,
                "fallback_reason" => "unpaired_function_call"
              }} = Compaction.validate_native_replay(replay)
    end
  end

  test "project_compact_result_for_inspect strips ciphertext from compact JSON" do
    assert {:ok, data} =
             Compaction.persist_threshold_item(local_checkpoint_data(), cmp_item("cmp_json"),
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    result = %{
      "ok" => true,
      "recorded" => true,
      "event" => data,
      "checkpoint" => %{"data" => data}
    }

    projected = Compaction.project_compact_result_for_inspect(result)
    encoded = Jason.encode!(projected)

    assert projected["event"]["native_replay"]["mode"] == "threshold_item"
    assert projected["event"]["native_replay"]["compaction_item_ids"] == ["cmp_json"]
    refute Map.has_key?(projected["event"]["native_replay"], "items")
    refute encoded =~ "encrypted_content"
    refute encoded =~ "CIPHERTEXT"
  end

  test "inspect_native_replay shows mode, usable, and ids without ciphertext" do
    assert {:ok, data} =
             Compaction.persist_threshold_item(local_checkpoint_data(), cmp_item("cmp_inspect"),
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    inspected = Compaction.inspect_native_replay(data)
    encoded = Jason.encode!(inspected)
    projected = Compaction.project_checkpoint_for_inspect(data)
    projected_json = Jason.encode!(projected)

    assert inspected == %{
             "mode" => "threshold_item",
             "recorded_usable" => true,
             "compaction_item_ids" => ["cmp_inspect"]
           }

    refute Map.has_key?(inspected, "items")
    refute encoded =~ "encrypted_content"
    refute encoded =~ "CIPHERTEXT"
    refute projected_json =~ "encrypted_content"
    refute projected_json =~ "CIPHERTEXT"
    assert projected["native_replay"]["mode"] == "threshold_item"
    assert projected["summary"] == data["summary"]
  end

  test "native_replay_fold_usable? can be true while provider_history still keeps local text", %{
    sid: sid
  } do
    assert {:ok, data} =
             Compaction.persist_threshold_item(local_checkpoint_data(), cmp_item("cmp_fold"),
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    current = %{
      "provider" => "openai_responses",
      "backend" => "chatgpt_codex",
      "dialect" => "chatgpt_codex",
      "model" => "gpt-5.5"
    }

    assert Compaction.native_replay_fold_usable?(data, current)
    refute Compaction.native_replay_fold_usable?(data, %{current | "model" => "other-model"})

    history = [
      Event.user_message(sid, "old") |> Event.with_seq(0),
      Event.history_compaction(sid, data) |> Event.with_seq(1),
      Event.user_message(sid, "recent") |> Event.with_seq(3)
    ]

    assert [%{type: :history_compaction, data: checkpoint}, %{type: :user_message}] =
             Compaction.provider_history(history)

    rendered = Compaction.render_for_provider(checkpoint)
    assert rendered =~ "Compressed session memory"
    assert rendered =~ checkpoint["summary"]
    refute rendered =~ "CIPHERTEXT"
    refute rendered =~ "cmp_fold"
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

  test "model-assisted compaction propagates profile preflight errors without fallback", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    cases = [{%{"mode" => "future"}, :invalid_config}]

    for {profile, kind} <- cases do
      assert {:error, %{error: %{kind: ^kind}} = payload} =
               Compaction.compact(sid,
                 workspace: ws,
                 tail_events: 1,
                 model_assisted: true,
                 responses_backend: profile,
                 auth: :missing_compaction_profile_auth,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )

      refute Map.has_key?(payload, "model_assisted_fallback")
    end

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    refute Enum.any?(history, &(&1.type == :history_compaction))
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

  test "model-assisted compaction receives snapshotted Provider defaults", %{ws: ws, sid: sid} do
    auth = start_auth()

    append_history(ws, [
      Event.user_message(sid, "implement compaction"),
      Event.assistant_message(sid, "working"),
      Event.user_message(sid, "continue")
    ])

    test = self()
    delegate = compaction_transport(valid_model_checkpoint())

    transport = fn request, acc, fun ->
      send(test, {:compaction_request, Jason.decode!(request.body)})
      delegate.(request, acc, fun)
    end

    assert {:ok, %{"recorded" => true, "model_assisted" => true}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               model_assisted: true,
               raw_config: %{
                 "reasoning" => %{"effort" => "high"},
                 "text" => %{"verbosity" => "low"}
               },
               auth: auth,
               transport: transport
             )

    assert_received {:compaction_request, body}
    assert body["reasoning"] == %{"effort" => "high"}
    assert body["text"]["format"]["name"] == "pixir_history_compaction_checkpoint"
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

  test "chatgpt_codex overlay-on compact stays local and does not POST /compact", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    assert {:ok, result} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               transport: fn _request, _acc, _fun ->
                 flunk("chatgpt_codex standalone compact must not POST /compact")
               end
             )

    assert result["recorded"] == true
    assert result["event"]["trigger"] == "manual"
    assert result["event"]["summary"]
    refute Map.has_key?(result["event"], "native_replay")
    assert result["native_replay_usable"] == false
    assert result["native_replay_reason"] == "native_unavailable"

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    compaction = Enum.find(history, &(&1.type == :history_compaction))
    assert compaction.data["trigger"] == "manual"
    refute Map.has_key?(compaction.data, "native_replay")
    refute Enum.any?(history, &(&1.type == :provider_usage))
  end

  test "official api.openai.com overlay-on compact persists entire standalone_window", %{
    ws: ws,
    sid: sid
  } do
    output = standalone_output("cmp_overlay_on")

    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => event} = result} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               responses_backend: official_responses_backend(),
               transport: standalone_transport(output)
             )

    assert_received {:compact_request, request}
    assert request.url == "https://api.openai.com/v1/responses/compact"
    body = Jason.decode!(request.body)
    assert body["store"] == false
    refute Map.has_key?(body, "stream")
    refute Map.has_key?(body, "compact_threshold")
    refute Map.has_key?(body, "context_management")
    refute Map.has_key?(body, "previous_response_id")
    assert length(body["input"]) == 2

    replay = event["native_replay"]
    assert replay["mode"] == "standalone_window"
    assert replay["recorded_usable"] == true
    assert replay["items"] == output
    assert replay["compaction_item_ids"] == ["cmp_overlay_on"]
    assert replay["provider"] == "openai_responses"
    assert replay["backend"] == "open_responses"
    assert replay["dialect"] == "open_responses"
    refute Map.has_key?(replay, "fallback_reason")
    assert result["native_replay_usable"] == true
    assert event["summary"]
    assert event["range"]["from_seq"] == 0
    refute Map.has_key?(event, "previous_response_id")

    assert {:ok, history} = Log.fold(sid, workspace: ws)
    assert Enum.any?(history, &(&1.type == :user_message and &1.data["text"] == "one"))
    assert Enum.any?(history, &(&1.type == :history_compaction))

    usage = Enum.find(history, &(&1.type == :provider_usage))
    assert usage.data["call_role"] == "compaction"
    assert usage.data["native_compact"]["mode"] == "standalone_window"
    assert usage.data["native_compact"]["recorded_usable"] == true
    refute inspect(usage.data) =~ "CIPHERTEXT"
    refute inspect(usage.data) =~ "encrypted_content"

    folded =
      history
      |> Compaction.provider_history()
      |> Provider.fold_input_items("gpt-5.5", native_replay_current: official_capturing_current())

    assert Enum.any?(folded, &(&1["type"] == "compaction" and &1["id"] == "cmp_overlay_on"))

    refute Enum.any?(folded, fn item ->
             is_map(item) and
               (item["call_role"] == "compaction" or item["type"] == "provider_usage")
           end)

    encoded = Jason.encode!(Compaction.project_compact_result_for_inspect(%{"event" => event}))
    refute encoded =~ "CIPHERTEXT"
    refute encoded =~ "encrypted_content"
  end

  test "standalone 404 and transport failures are not malformed_native_replay", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    not_found = fn http_request, acc, fun ->
      send(self(), {:compact_request, http_request})
      acc = fun.({:status, 404}, acc)
      acc = fun.({:data, ~s({"error":{"message":"not found"}})}, acc)
      {:ok, acc}
    end

    assert {:ok, result} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               responses_backend: official_responses_backend(),
               transport: not_found
             )

    assert_received {:compact_request, request}
    assert String.ends_with?(request.url, "/compact")
    assert result["recorded"] == true
    assert result["event"]["summary"]
    assert result["native_replay_usable"] == false
    assert result["native_replay_reason"] == "http_404"
    replay = result["event"]["native_replay"]
    assert replay["mode"] == "standalone_window"
    assert replay["recorded_usable"] == false
    assert replay["fallback_reason"] == "http_404"
    assert replay["items"] == []
    refute Compaction.native_replay_fold_usable?(result["event"], official_capturing_current())

    sid2 = sid <> "-transport"

    append_history(ws, [
      Event.user_message(sid2, "one"),
      Event.assistant_message(sid2, "two"),
      Event.user_message(sid2, "three")
    ])

    assert {:ok, transport_result} =
             Compaction.compact(sid2,
               workspace: ws,
               tail_events: 1,
               responses_backend: official_responses_backend(),
               transport: fn _request, _acc, _fun -> {:error, :econnrefused} end
             )

    assert transport_result["native_replay_reason"] == "transport"
    assert transport_result["event"]["native_replay"]["fallback_reason"] == "transport"
    assert transport_result["event"]["native_replay"]["recorded_usable"] == false
    assert transport_result["event"]["summary"]
  end

  test "explicit compaction.native false stays local and does not call compact client", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => event}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               native: false,
               transport: fn _request, _acc, _fun ->
                 flunk("standalone compact client must not run")
               end
             )

    refute Map.has_key?(event, "native_replay")
  end

  test "open_responses and Anthropic explicit compact stay local", %{ws: ws, sid: sid} do
    append_history(ws, [
      Event.user_message(sid, "one"),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    flunk_transport = fn _request, _acc, _fun ->
      flunk("standalone compact client must not run")
    end

    assert {:ok, %{"recorded" => true, "event" => open_event}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1,
               responses_backend: %{
                 "mode" => "open_responses",
                 "responses_url" => "https://vendor.example/v1/responses",
                 "auth" => %{"policy" => "none"}
               },
               transport: flunk_transport
             )

    refute Map.has_key?(open_event, "native_replay")

    sid2 = sid <> "-ant"

    append_history(ws, [
      Event.user_message(sid2, "one"),
      Event.assistant_message(sid2, "two"),
      Event.user_message(sid2, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => anthropic_event}} =
             Compaction.compact(sid2,
               workspace: ws,
               tail_events: 1,
               provider: Pixir.Providers.Anthropic,
               native: true,
               transport: flunk_transport
             )

    refute Map.has_key?(anthropic_event, "native_replay")
  end

  test "recovery triggers stay local even when overlay is on", %{ws: ws, sid: sid} do
    auth = start_auth()

    for trigger <- [
          "overflow_recovery",
          "critical_pressure_preflight",
          "websocket_critical_recovery"
        ] do
      trigger_sid = sid <> "-" <> trigger

      append_history(ws, [
        Event.user_message(trigger_sid, "one"),
        Event.assistant_message(trigger_sid, "two"),
        Event.user_message(trigger_sid, "three")
      ])

      assert {:ok, %{"recorded" => true, "event" => event}} =
               Compaction.compact(trigger_sid,
                 workspace: ws,
                 tail_events: 1,
                 trigger: trigger,
                 auth: auth,
                 native: true,
                 transport: fn _request, _acc, _fun ->
                   flunk("standalone compact client must not run for #{trigger}")
                 end
               )

      refute Map.has_key?(event, "native_replay")
      assert event["trigger"] == trigger
    end
  end

  test "persist_standalone_window marks standalone_window_pruned when output is reduced to cmp_" do
    cmp = cmp_item("cmp_pruned")
    output = [%{"type" => "message", "role" => "assistant", "content" => "kept"}, cmp]

    assert {:ok, %{"native_replay" => replay}} =
             Compaction.persist_standalone_window(local_checkpoint_data(), [cmp],
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5",
               compact_output: output
             )

    assert replay["recorded_usable"] == false
    assert replay["fallback_reason"] == "standalone_window_pruned"
  end

  test "unusable standalone blobs fold local text with structured fallback_reason" do
    missing_cipher = [
      %{"type" => "message", "role" => "user", "content" => "kept"},
      %{"type" => "compaction", "id" => "cmp_plain", "encrypted_content" => ""}
    ]

    assert {:ok, data} =
             Compaction.persist_standalone_window(local_checkpoint_data(), missing_cipher,
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert data["native_replay"]["fallback_reason"] == "missing_encrypted_content"
    refute Compaction.native_replay_fold_usable?(data, capturing_current())

    unpaired = [
      %{"type" => "function_call", "name" => "read"},
      cmp_item("cmp_unpaired")
    ]

    assert {:ok, unpaired_data} =
             Compaction.persist_standalone_window(local_checkpoint_data(), unpaired,
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert unpaired_data["native_replay"]["fallback_reason"] == "unpaired_function_call"
    refute Compaction.native_replay_fold_usable?(unpaired_data, capturing_current())
  end

  test "compact_threshold product N is distinct from the OpenAI API minimum" do
    assert Compaction.compact_threshold() == 200_000
    assert Compaction.compact_threshold_minimum() == 1_000
    assert Compaction.compact_threshold() > Compaction.compact_threshold_minimum()
  end

  test "C and D read the same compaction.native overlay preference" do
    chatgpt = capturing_current()

    assert Compaction.native_preference([]) == nil
    assert Compaction.native_preference(native: false) == false
    assert Compaction.native_preference(native: true) == true
    assert {:on, nil} = Compaction.overlay_after_resolve(nil, chatgpt)
    assert {:on, nil} = Compaction.overlay_after_resolve(true, chatgpt)
    assert {:off, "overlay_off"} = Compaction.overlay_after_resolve(false, chatgpt)

    assert {:off, "native_unavailable"} =
             Compaction.overlay_after_resolve(nil, %{
               "provider" => "openai_responses",
               "backend" => "open_responses",
               "dialect" => "open_responses",
               "model" => "gpt-5.5"
             })

    assert {:off, "native_unavailable"} =
             Compaction.overlay_after_resolve(true, %{
               "provider" => "anthropic",
               "backend" => "not_applicable",
               "dialect" => "anthropic",
               "model" => "claude-fable-5"
             })

    assert {:on, nil} =
             Compaction.overlay_after_resolve(nil, %{
               "provider" => "openai_responses",
               "backend" => "open_responses",
               "dialect" => "open_responses",
               "model" => "gpt-5.5",
               "responses_host" => "official_responses"
             })

    assert "http_404" in Compaction.NativeReplay.fallback_reasons()
    assert "transport" in Compaction.NativeReplay.fallback_reasons()
  end

  test "native_threshold_event_data freezes to_seq at input_to_seq and keeps a singleton cmp_" do
    sid = "sess-threshold-seq"

    history = [
      Event.user_message(sid, "old") |> Event.with_seq(0),
      Event.assistant_message(sid, "old answer") |> Event.with_seq(1),
      Event.user_message(sid, "current") |> Event.with_seq(2)
    ]

    assert Compaction.input_to_seq(history) == 2

    item = cmp_item("cmp_to_seq")

    assert {:ok, data} =
             Compaction.native_threshold_event_data(history, 2, item,
               provider: "openai_responses",
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert data["trigger"] == "native_threshold"
    assert data["range"]["to_seq"] == 2
    assert data["summary"]
    replay = data["native_replay"]
    assert replay["mode"] == "threshold_item"
    assert replay["recorded_usable"] == true
    assert replay["items"] == [item]
    refute Enum.any?(replay["items"], &(&1["type"] == "message"))
  end

  test "native_threshold with no compactable prefix still writes an honest local checkpoint" do
    assert Compaction.input_to_seq([]) == nil

    assert {:ok, data} =
             Compaction.native_threshold_event_data([], nil, cmp_item("cmp_empty_prefix"),
               provider: "openai_responses",
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert data["trigger"] == "native_threshold"
    assert data["range"] == %{"from_seq" => 0, "to_seq" => 0}
    assert data["source_event_count"] == 0
    assert data["summary"] =~ "no additional compactable prefix events"
    assert data["limitations"] != []
    assert data["native_replay"]["recorded_usable"] == true
  end

  test "failed threshold capture still writes local text with recorded_usable false" do
    sid = "sess-threshold-fallback"

    history = [
      Event.user_message(sid, "one") |> Event.with_seq(0),
      Event.assistant_message(sid, "two") |> Event.with_seq(1)
    ]

    assert {:ok, data} =
             Compaction.native_threshold_event_data(
               history,
               1,
               %{"type" => "compaction", "id" => "cmp_empty"},
               provider: "openai_responses",
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert data["trigger"] == "native_threshold"
    assert data["range"]["to_seq"] == 1
    assert data["summary"]
    assert data["native_replay"]["recorded_usable"] == false
    assert data["native_replay"]["fallback_reason"] == "missing_encrypted_content"
  end

  test "compact_threshold_suppressed? keys hysteresis to the current checkpoint range" do
    sid = "sess-threshold-hysteresis"

    usage =
      Event.provider_usage(sid, %{
        "native_compact" => %{
          "mode" => "threshold_item",
          "fallback_reason" => "backend_rejected",
          "checkpoint_to_seq" => nil
        }
      })
      |> Event.with_seq(1)

    history = [Event.user_message(sid, "hi") |> Event.with_seq(0), usage]
    assert Compaction.compact_threshold_suppressed?(history)

    checkpoint =
      Event.history_compaction(sid, %{
        "range" => %{"from_seq" => 0, "to_seq" => 0},
        "strategy" => "deterministic_operational_summary_v1",
        "summary" => "later local compact",
        "limitations" => ["full Log remains authoritative"]
      })
      |> Event.with_seq(2)

    refute Compaction.compact_threshold_suppressed?(history ++ [checkpoint])
  end

  test "persist_threshold_item does not raise on unstringifiable keys or validate errors" do
    assert {:error, %{error: %{kind: :malformed_native_replay}}} =
             Compaction.persist_threshold_item(
               Map.put(local_checkpoint_data(), 1, "bad"),
               cmp_item("cmp_bad"),
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )

    assert {:error, %{error: %{kind: :malformed_native_replay}}} =
             Compaction.persist_threshold_item(local_checkpoint_data(), [%{1 => "bad"}],
               backend: "chatgpt_codex",
               dialect: "chatgpt_codex",
               model: "gpt-5.5"
             )
  end

  test "compacted skill_activation stays out of replay and limitation is recorded", %{
    ws: ws,
    sid: sid
  } do
    append_history(ws, [
      Event.user_message(sid, "one"),
      skill_activation_event(sid),
      Event.assistant_message(sid, "two"),
      Event.user_message(sid, "three")
    ])

    assert {:ok, %{"recorded" => true, "event" => event}} =
             Compaction.compact(sid,
               workspace: ws,
               tail_events: 1
             )

    assert @skill_limitation in event["limitations"]
    assert event["compacted_skill_activation_count"] >= 1

    history = [
      Event.history_compaction(sid, event) |> Event.with_seq(4),
      Event.user_message(sid, "recent") |> Event.with_seq(5)
    ]

    folded = Compaction.provider_history(history)
    refute Enum.any?(folded, &(&1.type == :skill_activation))
  end

  defp start_auth do
    name = :"auth_#{System.unique_integer([:positive])}"
    path = tmp_auth_store("pixir-compaction-auth-")

    {:ok, _} =
      Auth.start_link(
        name: name,
        store_path: path,
        env_api_key: "sk-test",
        oauth: __MODULE__.NoOAuth
      )

    name
  end

  defp tmp_auth_store(prefix) do
    directory =
      Path.join(
        System.tmp_dir!(),
        prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.rm_rf!(directory)
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    Path.join(directory, "auth.json")
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

  defp local_checkpoint_data do
    %{
      "range" => %{"from_seq" => 0, "to_seq" => 2},
      "strategy" => "deterministic_operational_summary_v1",
      "summary" => "Compacted old context.",
      "limitations" => ["full Log remains authoritative"],
      "source_event_count" => 3,
      "files_touched" => [],
      "open_tasks" => []
    }
  end

  defp cmp_item(id) do
    %{
      "type" => "compaction",
      "id" => id,
      "encrypted_content" => "CIPHERTEXT_#{id}"
    }
  end

  defp capturing_current do
    %{
      "provider" => "openai_responses",
      "backend" => "chatgpt_codex",
      "dialect" => "chatgpt_codex",
      "model" => "gpt-5.5"
    }
  end

  defp official_capturing_current do
    %{
      "provider" => "openai_responses",
      "backend" => "open_responses",
      "dialect" => "open_responses",
      "model" => "gpt-5.5"
    }
  end

  defp official_responses_backend do
    %{
      "mode" => "open_responses",
      "responses_url" => "https://api.openai.com/v1/responses",
      "auth" => %{"policy" => "none"}
    }
  end

  defp standalone_output(id) do
    [
      %{"type" => "message", "role" => "user", "content" => "kept prefix"},
      cmp_item(id)
    ]
  end

  defp standalone_transport(output, usage \\ %{"input_tokens" => 11, "output_tokens" => 3}) do
    test = self()
    payload = %{"output" => output, "usage" => usage}

    fn http_request, acc, fun ->
      send(test, {:compact_request, http_request})
      acc = fun.({:status, 200}, acc)
      acc = fun.({:data, Jason.encode!(payload)}, acc)
      {:ok, acc}
    end
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
