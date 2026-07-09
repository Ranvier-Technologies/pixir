defmodule Pixir.EventReasoningDialectTest do
  use ExUnit.Case, async: true

  alias Pixir.Event

  test "reasoning dialect is additive and omitted when absent" do
    old = Event.reasoning("s", %{"type" => "reasoning", "id" => "rs_1"}, "gpt-5.5")
    refute Map.has_key?(old.data, "dialect")

    anthropic =
      Event.reasoning("s", %{"type" => "thinking", "signature" => "sig"}, "claude-fable-5",
        dialect: "anthropic"
      )

    assert anthropic.data["dialect"] == "anthropic"
  end
end
