defmodule Pixir.Providers.AnthropicReplayTest do
  use ExUnit.Case, async: true

  alias Pixir.Event
  alias Pixir.Provider
  alias Pixir.Providers.Anthropic.Replay

  test "replayable_block returns anthropic blocks byte-identically on matching model" do
    block = %{
      "type" => "thinking",
      "thinking" => "",
      "signature" => "sig+/= byte untouched",
      "extra" => %{"nested" => ["kept"]}
    }

    data = %{"dialect" => "anthropic", "model" => "claude-fable-5", "item" => block}

    assert {:ok, ^block} = Replay.replayable_block(data, "claude-fable-5")
  end

  test "replayable_block drops old OpenAI events and cross-model Anthropic events" do
    block = %{"type" => "thinking", "signature" => "sig"}

    assert :drop =
             Replay.replayable_block(
               %{"model" => "claude-fable-5", "item" => block},
               "claude-fable-5"
             )

    assert :drop =
             Replay.replayable_block(
               %{"dialect" => "anthropic", "model" => "claude-fable-5", "item" => block},
               "claude-other"
             )
  end

  test "assistant_content preserves reasoning/tool positions through renderer seam" do
    thinking = %{"type" => "thinking", "thinking" => "a", "signature" => "sig-a"}
    redacted = %{"type" => "redacted_thinking", "data" => "opaque", "signature" => "sig-b"}

    items = [
      Event.reasoning("s", thinking, "claude-fable-5", dialect: "anthropic"),
      Event.tool_call("s", "toolu_1", "read", %{"path" => "a.txt"}),
      Event.reasoning("s", redacted, "claude-fable-5", dialect: "anthropic")
    ]

    render = fn %{type: :tool_call, data: data} ->
      %{
        "type" => "tool_use",
        "id" => data["call_id"],
        "name" => data["name"],
        "input" => data["args"]
      }
    end

    assert Replay.assistant_content(items, "claude-fable-5", render) == [
             thinking,
             %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "read",
               "input" => %{"path" => "a.txt"}
             },
             redacted
           ]
  end

  test "OpenAI request fold drops anthropic-dialect reasoning even on model match" do
    raw = %{"type" => "thinking", "thinking" => "secret", "signature" => "sig"}

    {:ok, body} =
      Provider.request_body_preview(
        %{
          history: [Event.reasoning("s", raw, "gpt-5.5", dialect: "anthropic")]
        },
        model: "gpt-5.5"
      )

    refute raw in body["input"]
  end

  test "old raw NDJSON reasoning line has no dialect and replays as OpenAI" do
    line =
      ~s({"id":"e1","session_id":"s","seq":0,"ts":"2026-07-09T00:00:00Z","type":"reasoning","data":{"item":{"type":"reasoning","id":"rs_1","encrypted_content":"abc"},"model":"gpt-5.5"}})

    # Mirror the Log decode contract: envelope keys become atoms, event `data`
    # stays STRING-keyed (the cold-read rule in test/AGENTS.md).
    decoded = Jason.decode!(line)
    event = %{type: :reasoning, session_id: decoded["session_id"], data: decoded["data"]}

    {:ok, body} = Provider.request_body_preview(%{history: [event]}, model: "gpt-5.5")

    assert %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "abc"} in body[
             "input"
           ]
  end
end
