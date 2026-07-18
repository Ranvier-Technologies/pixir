defmodule Pixir.Providers.ErrBodyTest do
  use ExUnit.Case, async: true

  alias Pixir.Providers.ErrBody

  test "new capture is empty and has no dropped-byte evidence" do
    capture = ErrBody.new()

    assert ErrBody.body(capture) == ""
    refute ErrBody.truncated?(capture)
  end

  test "retention cap remains the frozen 16 KiB contract" do
    assert ErrBody.max_bytes() == 16_384
  end

  test "under-cap and exact-cap appends preserve byte-exact bodies without truncation" do
    cap = ErrBody.max_bytes()

    for chunks <- [
          [String.duplicate("u", cap - 1)],
          [String.duplicate("e", cap)],
          [String.duplicate("c", div(cap, 2)), String.duplicate("d", div(cap, 2))],
          [String.duplicate("z", cap), ""]
        ] do
      capture = append_all(chunks)
      expected = IO.iodata_to_binary(chunks)

      assert ErrBody.body(capture) == expected
      assert byte_size(ErrBody.body(capture)) <= cap
      refute ErrBody.truncated?(capture)
    end
  end

  test "crossing the cap retains the prefix and records sticky dropped-byte evidence" do
    cap = ErrBody.max_bytes()

    for chunks <- [
          [String.duplicate("a", cap - 1), "bc"],
          [String.duplicate("b", cap), "c"],
          [String.duplicate("d", cap + 1)],
          [String.duplicate("e", cap + 1), "", "later"]
        ] do
      received = IO.iodata_to_binary(chunks)
      capture = append_all(chunks)
      expected = binary_part(received, 0, cap)

      assert ErrBody.body(capture) == expected
      assert byte_size(ErrBody.body(capture)) == cap
      assert ErrBody.truncated?(capture)
    end
  end

  test "an empty append after overflow preserves sticky provenance" do
    cap = ErrBody.max_bytes()

    capture =
      ErrBody.new()
      |> ErrBody.append(String.duplicate("x", cap + 1))
      |> ErrBody.append("")

    assert byte_size(ErrBody.body(capture)) == cap
    assert ErrBody.truncated?(capture)
  end

  test "capture remains byte-bounded when the cap splits a UTF-8 sequence" do
    cap = ErrBody.max_bytes()
    prefix = String.duplicate("a", cap - 1)
    capture = ErrBody.append(ErrBody.new(), prefix <> "é")

    assert ErrBody.body(capture) == prefix <> <<0xC3>>
    assert byte_size(ErrBody.body(capture)) == cap
    assert ErrBody.truncated?(capture)
  end

  defp append_all(chunks), do: Enum.reduce(chunks, ErrBody.new(), &ErrBody.append(&2, &1))
end
