defmodule Pixir.AnthropicUsageSummaryTest do
  use ExUnit.Case, async: true

  test "Anthropic provider seam keeps explicit cache evidence and TTL counters when present" do
    usage = %{
      "input_tokens" => 100,
      "cache_creation_input_tokens" => 30,
      "cache_read_input_tokens" => 20,
      "output_tokens" => 10,
      "cache_creation" => %{
        "ephemeral_5m_input_tokens" => 12,
        "ephemeral_1h_input_tokens" => 18
      }
    }

    transport = fn _request, acc, reducer ->
      acc = reducer.({:status, 200}, acc)
      acc = reducer.({:data, sse("message_start", %{"message" => %{"usage" => usage}})}, acc)

      acc =
        reducer.(
          {:data,
           sse("content_block_start", %{
             "index" => 0,
             "content_block" => %{"type" => "text", "text" => ""}
           })},
          acc
        )

      acc =
        reducer.(
          {:data,
           sse("content_block_delta", %{
             "index" => 0,
             "delta" => %{"type" => "text_delta", "text" => "ok"}
           })},
          acc
        )

      acc = reducer.({:data, sse("content_block_stop", %{"index" => 0})}, acc)

      acc =
        reducer.(
          {:data,
           sse("message_delta", %{
             "delta" => %{"stop_reason" => "end_turn"},
             "usage" => Map.put(usage, "output_tokens", 10)
           })},
          acc
        )

      acc = reducer.({:data, sse("message_stop", %{})}, acc)
      {:ok, acc}
    end

    assert {:ok, result} =
             Pixir.Providers.Anthropic.stream(
               %{model: "claude-fable-5", messages: [%{"role" => "user", "content" => "hi"}]},
               api_key: "test-key",
               transport: transport,
               max_retries: 0
             )

    summary = result.usage_summary
    assert summary["model"] == "claude-fable-5"
    assert summary["cached_tokens"] == 20

    assert summary["cache"] == %{
             "creation_tokens" => 30,
             "read_tokens" => 20,
             "ephemeral_5m_input_tokens" => 12,
             "ephemeral_1h_input_tokens" => 18
           }

    assert summary["cache_hit_rate"] == 20 / 150
  end

  defp sse(event, data), do: "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
end
