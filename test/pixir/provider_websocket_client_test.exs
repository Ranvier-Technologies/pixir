defmodule Pixir.Provider.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias Pixir.Provider.WebSocketClient

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
end
