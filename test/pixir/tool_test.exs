defmodule Pixir.ToolTest do
  use ExUnit.Case, async: true

  alias Pixir.Tool

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
end
