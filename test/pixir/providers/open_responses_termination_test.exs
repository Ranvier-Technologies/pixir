defmodule Pixir.Providers.OpenResponsesTerminationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Stream-termination tolerance for the open_responses profile (#208, HITL
  adjudication 2026-07-20). The openresponses.org spec requires the literal
  `[DONE]` sentinel as the terminal frame, but measured real implementations
  (Ollama 0.32.1) end the stream by closing after the typed terminal event,
  matching OpenAI's own Responses behavior. Pixir tolerates the clean-EOF
  ending and CONFESSES it: `done` stays strict sentinel evidence and
  `termination` names how the stream actually ended. Both variants here derive
  from the byte-pinned canonical fixture so the lineage stays single-source.
  """

  alias Pixir.Provider

  @fixture Path.expand("../../fixtures/provider/open_responses/text_and_tool_call.sse", __DIR__)

  defp open_profile do
    %{
      "mode" => "open_responses",
      "responses_url" => "https://vendor.invalid/v1/responses",
      "auth" => %{"policy" => "none"}
    }
  end

  defp quiet_stream_transport(chunks) do
    fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, Enum.reduce(chunks, acc, &fun.({:data, &1}, &2))}
    end
  end

  defp stream_fixture(stream) do
    Provider.stream(%{history: []},
      responses_backend: open_profile(),
      transport: quiet_stream_transport([stream]),
      max_retries: 0
    )
  end

  defp open_metadata({:ok, result}), do: result.provider_metadata["open_responses"]

  test "the sentinel-terminated canonical fixture reports done_sentinel" do
    assert {:ok, _result} = result = stream_fixture(File.read!(@fixture))

    open = open_metadata(result)
    assert open["done"] == true
    assert open["termination"] == "done_sentinel"
  end

  test "clean EOF after the terminal event is tolerated and confessed" do
    canonical = File.read!(@fixture)
    assert canonical =~ "data: [DONE]"
    without_done = String.replace(canonical, "data: [DONE]\n\n", "")
    refute without_done =~ "[DONE]"

    assert {:ok, _result} = result = stream_fixture(without_done)

    open = open_metadata(result)
    assert open["done"] == false
    assert open["termination"] == "eof_after_terminal"
    assert open["known_event_counts"]["response.completed"] == 1
  end

  test "a stream cut before any terminal event confesses eof_unterminated" do
    canonical = File.read!(@fixture)
    [head, _tail] = String.split(canonical, "event: response.completed", parts: 2)

    assert {:ok, result} = stream_fixture(head)

    open = result.provider_metadata["open_responses"]
    assert open["done"] == false
    assert open["termination"] == "eof_unterminated"
    refute Map.has_key?(open["known_event_counts"], "response.completed")
  end
end
