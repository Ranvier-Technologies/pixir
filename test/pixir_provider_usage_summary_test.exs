defmodule Pixir.ProviderUsageSummaryTest do
  use ExUnit.Case, async: true

  test "OpenAI usage summary exposes cache map parity without changing cached token semantics" do
    usage = %{
      "input_tokens" => 100,
      "output_tokens" => 20,
      "total_tokens" => 120,
      "input_tokens_details" => %{"cached_tokens" => 40},
      "output_tokens_details" => %{"reasoning_tokens" => 5}
    }

    summary = Pixir.Provider.usage_summary(usage)

    assert summary.cached_tokens == 40
    assert summary.cache_hit_rate == 40 / 100
    assert summary.cache == %{"creation_tokens" => 0, "read_tokens" => 40}
  end
end
