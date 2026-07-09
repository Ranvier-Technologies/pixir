defmodule Pixir.Provider.ContextWindowAnthropicTest do
  use ExUnit.Case, async: true

  test "claude-fable-5 has a built-in one million token context window" do
    assert Pixir.Provider.ContextWindow.window_tokens("claude-fable-5") == {:ok, 1_000_000}
  end
end
