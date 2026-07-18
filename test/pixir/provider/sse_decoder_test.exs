defmodule Pixir.Provider.SSEDecoderTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.SSEDecoder

  test "frames comments, unknown fields, multiline data, BOM, and every legal line ending" do
    for newline <- ["\n", "\r\n", "\r"] do
      stream =
        <<0xEF, 0xBB, 0xBF>> <>
          Enum.join(
            [
              ": comment",
              "retry: 1",
              "event: response.output_text.delta",
              "data: {\"type\":\"response.output_text.delta\",",
              "data: \"delta\":\"ok\"}",
              "",
              "data: [DONE]",
              "",
              ": after done",
              "",
              ""
            ],
            newline
          )

      assert {:ok, decoder, [frame, :done]} = SSEDecoder.feed(SSEDecoder.new(), stream)
      assert frame.event == "response.output_text.delta"
      assert frame.data == "{\"type\":\"response.output_text.delta\",\n\"delta\":\"ok\"}"
      assert frame.ordinal == 1

      assert {:ok, _decoder, [], %{done: true, discarded_pending: false}} =
               SSEDecoder.finish(decoder)
    end
  end

  test "arbitrary one-byte chunks preserve delimiters and split UTF-8 scalars" do
    stream =
      "event: response.output_text.delta\r\n" <>
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"a¢€😀\"}\r\n\r\n" <>
        "data: [DONE]\r\n\r\n"

    {decoder, frames} =
      stream
      |> :binary.bin_to_list()
      |> Enum.reduce({SSEDecoder.new(), []}, fn byte, {decoder, frames} ->
        assert {:ok, decoder, emitted} = SSEDecoder.feed(decoder, <<byte>>)
        {decoder, frames ++ emitted}
      end)

    assert [%{data: data}, :done] = frames
    assert Jason.decode!(data)["delta"] == "a¢€😀"
    assert {:ok, _decoder, [], %{done: true}} = SSEDecoder.finish(decoder)
  end

  test "all UTF-8 scalar widths are accepted at table-driven boundaries" do
    for scalar <- ["a", "¢", "€", "😀"], split <- 0..byte_size(scalar) do
      event = "data: " <> scalar <> "\n\n"
      boundary = byte_size("data: ") + split
      <<left::binary-size(^boundary), right::binary>> = event

      assert {:ok, decoder, left_frames} = SSEDecoder.feed(SSEDecoder.new(), left)
      assert {:ok, _decoder, right_frames} = SSEDecoder.feed(decoder, right)
      assert left_frames ++ right_frames == [%{event: nil, data: scalar, ordinal: 1}]
    end
  end

  test "at most one leading BOM is stripped" do
    assert {:ok, _decoder, [%{data: "x"}]} =
             SSEDecoder.feed(SSEDecoder.new(), <<0xEF, 0xBB, 0xBF>> <> "data: x\n\n")

    assert {:ok, _decoder, [%{data: data}]} =
             SSEDecoder.feed(
               SSEDecoder.new(),
               <<0xEF, 0xBB, 0xBF>> <> "data: " <> <<0xEF, 0xBB, 0xBF>> <> "x\n\n"
             )

    assert data == <<0xEF, 0xBB, 0xBF>> <> "x"
  end

  test "invalid UTF-8 fails with bounded evidence and no payload" do
    assert {:error, _decoder, [], error} =
             SSEDecoder.feed(SSEDecoder.new(), "data: " <> <<0xFF>> <> "\n\n")

    assert error.error.kind == :invalid_response
    assert error.error.details.reason == :invalid_utf8
    assert error.error.details.observed_bytes == 8
    refute inspect(error) =~ <<0xFF>>
  end

  test "EOF discards pending data instead of dispatching it" do
    assert {:ok, decoder, []} = SSEDecoder.feed(SSEDecoder.new(), "data: pending")

    assert {:ok, _decoder, [], summary} = SSEDecoder.finish(decoder)
    assert summary == %{done: false, discarded_pending: true, discarded_bytes: 13}

    assert {:ok, decoder, []} = SSEDecoder.feed(SSEDecoder.new(), "data: pending\r")

    assert {:ok, _decoder, [], %{discarded_pending: true, discarded_bytes: 14}} =
             SSEDecoder.finish(decoder)
  end

  test "a trailing lone CR is finalized as a line delimiter without inventing CRLF" do
    assert {:ok, decoder, []} = SSEDecoder.feed(SSEDecoder.new(), "data: x\r\r")

    assert {:ok, _decoder, [%{event: nil, data: "x", ordinal: 1}], summary} =
             SSEDecoder.finish(decoder)

    assert summary.discarded_pending == false
  end

  test "DONE is stateful: comments and blanks remain legal, duplicate or later events fail" do
    assert {:ok, done, [:done]} = SSEDecoder.feed(SSEDecoder.new(), "data: [DONE]\n\n")
    assert {:ok, _done, []} = SSEDecoder.feed(done, ": comment\n\n")

    for suffix <- ["data: [DONE]\n\n", "data: {}\n\n", "event: response.completed\n\n"] do
      assert {:error, _decoder, [], error} = SSEDecoder.feed(done, suffix)
      assert error.error.kind == :invalid_response
      assert error.error.details.reason == :event_after_done
    end
  end

  test "the exact 16 MiB framed event is accepted and one extra byte is rejected" do
    limit = SSEDecoder.max_event_bytes()
    exact = "data: " <> String.duplicate("x", limit - 8) <> "\n\n"

    assert byte_size(exact) == limit
    assert {:ok, _decoder, [%{data: data}]} = SSEDecoder.feed(SSEDecoder.new(), exact)
    assert byte_size(data) == limit - 8

    over = "data: " <> String.duplicate("x", limit - 7) <> "\n\n"
    assert {:error, _decoder, [], error} = SSEDecoder.feed(SSEDecoder.new(), over)
    assert error.error.details.reason == :event_too_large
    assert error.error.details.observed_bytes == limit + 1
    assert error.error.details.limit == limit
  end
end
