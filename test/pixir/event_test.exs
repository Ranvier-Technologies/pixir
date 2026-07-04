defmodule Pixir.EventTest do
  use ExUnit.Case, async: true

  alias Pixir.Event

  test "new/4 builds the full envelope with a fresh id, ts, and nil seq" do
    e = Event.new("s1", :status, %{"status" => "thinking"})

    assert %{id: id, session_id: "s1", seq: nil, ts: ts, type: :status, data: data} = e
    assert is_binary(id) and byte_size(id) > 0
    assert {:ok, _, _} = DateTime.from_iso8601(ts)
    assert data == %{"status" => "thinking"}
  end

  test "ids are unique across calls" do
    assert Event.new("s", :status, %{}).id != Event.new("s", :status, %{}).id
  end

  test "opts can pin id/ts/seq (deterministic construction)" do
    e =
      Event.new("s", :user_message, %{text: "hi"},
        id: "fixed",
        ts: "2026-01-01T00:00:00Z",
        seq: 7
      )

    assert e.id == "fixed"
    assert e.ts == "2026-01-01T00:00:00Z"
    assert e.seq == 7
    assert e.data == %{"text" => "hi"}
  end

  test "new/4 normalizes event data keys recursively and rejects invalid keys" do
    e = Event.new("s", :provider_usage, %{usage_summary: %{cached_tokens: 1}})
    assert e.data == %{"usage_summary" => %{"cached_tokens" => 1}}

    assert_raise ArgumentError, fn ->
      Event.new("s", :provider_usage, %{123 => "bad"})
    end
  end

  test "new/4 rejects event data key collisions after normalization" do
    assert_raise ArgumentError, ~r/key collision.*"model"/, fn ->
      Event.new("s", :provider_usage, %{:model => "gpt-a", "model" => "gpt-b"})
    end

    assert_raise ArgumentError, ~r/key collision.*"cached_tokens"/, fn ->
      Event.new("s", :provider_usage, %{
        "usage_summary" => %{:cached_tokens => 1, "cached_tokens" => 2}
      })
    end
  end

  test "canonical?/ephemeral? classify by type" do
    assert Event.canonical?(Event.user_message("s", "hi"))
    assert Event.canonical?(Event.assistant_message("s", "yo"))
    assert Event.canonical?(Event.tool_call("s", "c1", "read", %{"path" => "a.txt"}))
    assert Event.canonical?(Event.tool_result("s", "c1", %{"ok" => true, "output" => "ok"}))

    assert Event.canonical?(Event.reasoning("s", %{"id" => "rs_1"}, "gpt-test"))
    assert Event.canonical?(Event.skill_activation("s", %{"name" => "sample"}))
    assert Event.canonical?(Event.subagent_event("s", %{"subagent_id" => "sub_1"}))
    assert Event.canonical?(Event.workflow_event("s", %{"kind" => "workflow_started"}))
    assert Event.canonical?(Event.history_compaction("s", %{"summary" => "older context"}))
    assert Event.canonical?(Event.session_fork("s", %{"parent_session_id" => "p"}))
    assert Event.canonical?(Event.branch_summary("s", %{"summary" => "branch context"}))
    assert Event.canonical?(Event.provider_usage("s", %{"usage_summary" => %{}}))

    refute Event.canonical?(Event.text_delta("s", "ch"))
    assert Event.ephemeral?(Event.reasoning_delta("s", "ch"))
    assert Event.ephemeral?(Event.status("s", "thinking"))
  end

  test "context_pressure/2 is ephemeral by construction (ADR 0020 channel separation)" do
    event = Event.context_pressure("s", %{"tier" => "warning", "ratio" => 0.85})

    assert event.type == :context_pressure
    assert event.data["tier"] == "warning"
    assert Event.ephemeral?(event)
    refute Event.canonical?(event)
    refute :context_pressure in Event.canonical_types()
  end

  test "reasoning/3 carries the opaque item and capturing model (ADR 0007)" do
    item = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "ENC"}
    e = Event.reasoning("s", item, "gpt-test")
    assert e.type == :reasoning
    assert e.data == %{"item" => item, "model" => "gpt-test"}
  end

  test "skill_activation/2 carries a durable skill snapshot (ADR 0010)" do
    data = %{
      "name" => "sample",
      "scope" => "repo",
      "path" => "/tmp/SKILL.md",
      "content_hash" => "abc",
      "content" => "# Sample"
    }

    e = Event.skill_activation("s", data)
    assert e.type == :skill_activation
    assert e.data == data
  end

  test "subagent_event/2 carries durable lifecycle data (ADR 0011)" do
    data = %{
      "subagent_id" => "sub_1",
      "child_session_id" => "child_1",
      "event" => "finished",
      "status" => "completed",
      "agent" => "worker",
      "summary" => "done"
    }

    e = Event.subagent_event("s", data)
    assert e.type == :subagent_event
    assert e.data == data
  end

  test "history_compaction/2 carries a durable compaction checkpoint" do
    data = %{
      "range" => %{"from_seq" => 0, "to_seq" => 12},
      "summary" => "older context",
      "strategy" => "deterministic_operational_summary_v1"
    }

    e = Event.history_compaction("s", data)
    assert e.type == :history_compaction
    assert e.data == data
  end

  test "provider_usage/2 carries durable Provider accounting evidence" do
    data = %{
      "model" => "gpt-5.5",
      "call_index" => 0,
      "usage_summary" => %{cached_tokens: 128},
      "prompt_cache_key" => "px1:m_gpt-5.5:r_build:s_abc:t_def:k_ghi"
    }

    e = Event.provider_usage("s", data)
    assert e.type == :provider_usage
    assert e.data["usage_summary"] == %{"cached_tokens" => 128}
  end

  test "workflow_event/2 carries durable Workflow decision data" do
    data = %{
      "kind" => "checkpoint_decided",
      "workflow_id" => "wf",
      "step_id" => "inspect",
      "checkpoint_status" => "checkpoint_ready",
      "dependent_safe" => true
    }

    e = Event.workflow_event("s", data)
    assert e.type == :workflow_event
    assert e.data == data
  end

  test "with_seq stamps a monotonic seq" do
    e = Event.user_message("s", "hi") |> Event.with_seq(3)
    assert e.seq == 3
  end

  test "canonical and ephemeral type sets are disjoint" do
    assert Event.canonical_types() -- Event.ephemeral_types() == Event.canonical_types()
  end
end
