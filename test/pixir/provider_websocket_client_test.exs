defmodule Pixir.Provider.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.WebSocketClient

  test "endpoint errors expose only a bounded scheme projection" do
    endpoint = "http://HOST-SECRET.invalid/PATH-SECRET?access_token=TOKEN-SECRET"

    assert {:error,
            %{
              error: %{
                kind: :invalid_endpoint,
                details: %{endpoint: "<http_endpoint>"}
              }
            } = error} = WebSocketClient.connect(endpoint, [])

    inspected = inspect(error)
    refute inspected =~ "HOST-SECRET"
    refute inspected =~ "PATH-SECRET"
    refute inspected =~ "TOKEN-SECRET"
  end

  describe "response_id_from_event/1" do
    test "captures response ids from completed response envelopes" do
      assert WebSocketClient.response_id_from_event(%{
               "type" => "response.completed",
               "response" => %{"id" => "resp_completed"}
             }) == "resp_completed"
    end

    test "captures response ids from response_id fields" do
      assert WebSocketClient.response_id_from_event(%{
               "type" => "response.output_text.delta",
               "response_id" => "resp_delta"
             }) == "resp_delta"
    end

    test "captures response ids from response lifecycle events" do
      assert WebSocketClient.response_id_from_event(%{
               "type" => "response.created",
               "id" => "resp_created"
             }) == "resp_created"
    end

    test "captures response ids from response.in_progress envelopes" do
      assert WebSocketClient.response_id_from_event(%{
               "type" => "response.in_progress",
               "response" => %{"id" => "resp_in_progress"}
             }) == "resp_in_progress"
    end

    test "rejects non-response ids and nested item ids" do
      refute WebSocketClient.response_id_from_event(%{
               "type" => "response.output_item.added",
               "id" => "msg_123"
             })

      refute WebSocketClient.response_id_from_event(%{
               "type" => "response.function_call_arguments.done",
               "id" => "call_123"
             })

      refute WebSocketClient.response_id_from_event(%{
               "type" => "response.output_item.done",
               "item" => %{"id" => "resp_not_the_response"}
             })
    end
  end

  test "response.incomplete is terminal while preterminal lifecycle events are not" do
    assert WebSocketClient.terminal_event?("response.incomplete")
    assert WebSocketClient.terminal_event?("response.completed")
    assert WebSocketClient.terminal_event?("response.failed")
    refute WebSocketClient.terminal_event?("response.in_progress")
    refute WebSocketClient.terminal_event?("response.output_text.delta")
  end

  test "already-buffered terminal frames are folded without accepting nonterminal tail data" do
    incomplete = Jason.encode!(%{"type" => "response.incomplete"})
    split = div(byte_size(incomplete), 2)
    <<first::binary-size(^split), second::binary>> = incomplete

    frames =
      server_text_frame(%{"type" => "response.completed"}) <>
        server_text_frame(%{"type" => "response.output_text.delta", "delta" => "late"}) <>
        server_frame(0x1, false, first) <>
        server_frame(0x9, true, "ping") <>
        server_frame(0xA, true, "pong") <>
        server_frame(0x0, true, second)

    fun = fn {:data, chunk}, acc -> [chunk | acc] end
    parent = self()
    control_fun = fn frame -> send(parent, {:buffered_control, frame.opcode}) end

    chunks =
      WebSocketClient.fold_buffered_terminal_frames(frames, [], fun, control_fun)
      |> Enum.reverse()

    assert length(chunks) == 2
    assert Enum.at(chunks, 0) =~ "response.completed"
    assert Enum.at(chunks, 1) =~ "response.incomplete"
    refute Enum.any?(chunks, &(&1 =~ "late"))
    assert_received {:buffered_control, 0x9}
    assert_received {:buffered_control, 0xA}
  end

  defp server_text_frame(event) do
    payload = Jason.encode!(event)
    server_frame(0x1, true, payload)
  end

  defp server_frame(opcode, fin, payload) do
    first = if fin, do: 0x80 + opcode, else: opcode
    length = byte_size(payload)
    <<first, length>> <> payload
  end
end
