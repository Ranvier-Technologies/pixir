defmodule Pixir.ACP.ProtocolTest do
  use ExUnit.Case, async: true

  alias Pixir.ACP.Protocol

  describe "decode/1" do
    test "decodes a request (has id + method)" do
      line = ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}})
      assert {:request, 1, "initialize", %{"protocolVersion" => 1}} = Protocol.decode(line)
    end

    test "decodes a string id" do
      line = ~s({"jsonrpc":"2.0","id":"abc","method":"session/new","params":{}})
      assert {:request, "abc", "session/new", %{}} = Protocol.decode(line)
    end

    test "defaults params to an empty map when absent" do
      line = ~s({"jsonrpc":"2.0","id":1,"method":"initialize"})
      assert {:request, 1, "initialize", %{}} = Protocol.decode(line)
    end

    test "decodes a notification (method, no id)" do
      line = ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s1"}})
      assert {:notification, "session/cancel", %{"sessionId" => "s1"}} = Protocol.decode(line)
    end

    test "a blank string id is treated as a notification (not a request)" do
      # effect-acp (T3 Code's ACP client) serializes the `session/cancel`
      # notification with an empty-string id (`"id":""`) instead of omitting it.
      # A blank id is not a usable JSON-RPC request id, so this must classify as
      # a notification — otherwise `session/cancel` falls through to -32601 and
      # never interrupts the turn (the STOP-button bug).
      line = ~s({"jsonrpc":"2.0","id":"","method":"session/cancel","params":{"sessionId":"s1"}})
      assert {:notification, "session/cancel", %{"sessionId" => "s1"}} = Protocol.decode(line)
    end

    test "malformed JSON is a parse error" do
      assert {:error, {:parse, -32_700, "Parse error"}} = Protocol.decode("{not json")
    end

    test "a non-2.0 envelope is an invalid request" do
      line = ~s({"jsonrpc":"1.0","id":1,"method":"x"})
      assert {:error, {:invalid_request, -32_600, "Invalid Request"}} = Protocol.decode(line)
    end

    test "a JSON scalar is an invalid request" do
      assert {:error, {:invalid_request, -32_600, _}} = Protocol.decode("42")
    end

    test "a request with non-object params is an invalid request (no transport crash)" do
      # Handlers call Map.get/2 on params; a list/scalar must be rejected at
      # decode time rather than forwarded and raised on downstream.
      line = ~s({"jsonrpc":"2.0","id":1,"method":"session/new","params":[]})
      assert {:error, {:invalid_request, -32_600, _}} = Protocol.decode(line)
    end

    test "a notification with non-object params is an invalid request" do
      line = ~s({"jsonrpc":"2.0","method":"session/cancel","params":null})
      assert {:error, {:invalid_request, -32_600, _}} = Protocol.decode(line)
    end

    test "a success response (id + result, no method) decodes to {:response, ...}" do
      line =
        ~s({"jsonrpc":"2.0","id":7,"result":{"outcome":{"outcome":"selected","optionId":"allow"}}})

      assert {:response, 7, %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}} =
               Protocol.decode(line)
    end

    test "an error response (id + error, no method) decodes to {:response_error, ...}" do
      line = ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32603,"message":"boom"}})

      assert {:response_error, 7, %{"code" => -32_603, "message" => "boom"}} =
               Protocol.decode(line)
    end

    test "an id-less response is still ignored" do
      line = ~s({"jsonrpc":"2.0","result":{}})
      assert {:ignore, nil} = Protocol.decode(line)
    end
  end

  describe "encoders" do
    test "result/2 round-trips through decode-as-JSON" do
      json = Protocol.result(7, %{"sessionId" => "s1"})

      assert Jason.decode!(json) == %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "result" => %{"sessionId" => "s1"}
             }
    end

    test "request/3 encodes an outbound request with id + method + params" do
      json = Protocol.request(-1, "session/request_permission", %{"sessionId" => "s1"})

      refute String.ends_with?(json, "\n")

      assert Jason.decode!(json) == %{
               "jsonrpc" => "2.0",
               "id" => -1,
               "method" => "session/request_permission",
               "params" => %{"sessionId" => "s1"}
             }
    end

    test "request/3 rejects ids that would not route a response" do
      assert_raise ArgumentError, fn ->
        Protocol.request("", "session/request_permission", %{})
      end

      assert_raise ArgumentError, fn ->
        apply(Protocol, :request, [nil, "session/request_permission", %{}])
      end
    end

    test "error/3 omits data when nil" do
      json = Protocol.error(7, -32_601, "method not found")
      decoded = Jason.decode!(json)
      assert decoded["error"] == %{"code" => -32_601, "message" => "method not found"}
      refute Map.has_key?(decoded["error"], "data")
    end

    test "error/4 includes data when given" do
      json = Protocol.error(7, -32_603, "boom", %{"kind" => "io"})
      assert Jason.decode!(json)["error"]["data"] == %{"kind" => "io"}
    end

    test "error with nil id encodes id as null" do
      json = Protocol.error(nil, -32_700, "Parse error")
      assert %{"id" => nil} = Jason.decode!(json)
    end

    test "notification/2 has method + params and no id" do
      json = Protocol.notification("session/update", %{"sessionId" => "s1", "update" => %{}})
      decoded = Jason.decode!(json)
      assert decoded["method"] == "session/update"
      assert decoded["params"]["sessionId"] == "s1"
      refute Map.has_key?(decoded, "id")
    end

    test "encoders emit no trailing newline (the Server appends it)" do
      refute String.ends_with?(Protocol.result(1, %{}), "\n")
      refute String.ends_with?(Protocol.notification("m", %{}), "\n")
      refute String.ends_with?(Protocol.error(1, -1, "x"), "\n")
      refute String.ends_with?(Protocol.request(-1, "session/request_permission", %{}), "\n")
    end
  end
end
