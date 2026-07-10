defmodule Pixir.Providers.ErrBodyTest do
  use ExUnit.Case, async: true

  alias Pixir.Providers.ErrBody

  test "append below cap preserves content" do
    assert ErrBody.append("hello", " world") == "hello world"
    refute ErrBody.truncated?("hello world")
  end

  test "append crossing cap truncates to max bytes" do
    body = ErrBody.append(String.duplicate("a", ErrBody.max_bytes() - 1), "bc")

    assert byte_size(body) == ErrBody.max_bytes()
    assert body == String.duplicate("a", ErrBody.max_bytes() - 1) <> "b"
    assert ErrBody.truncated?(body)
  end

  test "append to already capped binary is a no-op" do
    capped = String.duplicate("a", ErrBody.max_bytes())

    assert ErrBody.append(capped, "ignored") == capped
  end
end
