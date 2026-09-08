defmodule Pixir.ToolTest do
  use ExUnit.Case, async: true

  alias Pixir.Tool

  test "truncate reserves marker bytes inside the requested total budget" do
    for budget <- [0, 1, 2, 3, 14, 32, 64, 100, 16_000] do
      result = Tool.truncate(String.duplicate("🛡️abc", 4_000), {:total_bytes, budget})
      assert byte_size(result) <= budget
      assert String.valid?(result)
      if budget >= 64, do: assert(result =~ "…[truncated, showing up to ")
    end
  end

  test "truncate is UTF-8 safe at multibyte boundaries" do
    text = String.duplicate("a", 15_999) <> "🛡️"

    truncated = Tool.truncate(text, 16_000)

    assert String.valid?(truncated)
    assert truncated =~ "[truncated"
    refute truncated =~ <<0xF0, 0x9F>>
  end

  test "truncate replaces invalid input bytes even when no size truncation is needed" do
    truncated = Tool.truncate(<<"ok ", 0xF0, 0x9F>>, 16_000)

    assert String.valid?(truncated)
    assert truncated =~ "ok "
    assert truncated =~ "�"
  end

  test "integer budgets preserve legacy prefix and marker semantics" do
    output = Tool.truncate("abcdef", 3)
    assert String.starts_with?(output, "abc\n…[truncated, showing up to 3")
  end

  test "total-byte budgets normalize invalid UTF-8 before accounting" do
    for budget <- [1, 14, 64, 100] do
      output = Tool.truncate(:binary.copy(<<255>>, 200), {:total_bytes, budget})
      assert String.valid?(output)
      assert byte_size(output) <= budget
    end
  end
end
