defmodule PixirMonitor.Projection.AdvisoryTest do
  @moduledoc """
  Pins the shared advisory classifier used by Runs inventory and full detail.
  """
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Advisory

  test "classifies a checkpoint declaration and derives gate disagreement" do
    raw =
      Jason.encode!(%{
        "checkpoint_status" => "checkpoint_ready",
        "summary" => "Bounded work completed."
      })

    assert {:ok,
            %{
              "present" => true,
              "parse_status" => "valid",
              "verdict" => "unknown",
              "declared_gate" => "checkpoint_ready"
            } = advisory} = Advisory.classify(raw)

    assert {:ok, ["advisory_gate_disagreement"]} =
             Advisory.attention_reasons(advisory, "not_applicable")
  end

  test "preserves stop precedence and malformed structured summaries" do
    assert {:ok, %{"verdict" => "stop"} = stop} =
             Advisory.classify(Jason.encode!(%{"mergeable" => false, "checkpoint_status" => "checkpoint_ready"}))

    assert {:ok, ["advisory_stop"]} = Advisory.attention_reasons(stop, "checkpoint_ready")

    assert {:ok, %{"present" => true, "parse_status" => "invalid"} = invalid} =
             Advisory.classify("{not-json")

    assert {:ok, ["advisory_unparseable"]} =
             Advisory.attention_reasons(invalid, "not_applicable")
  end

  test "cautionary explicit verdicts override mergeable true" do
    for verdict <- ~w(stop needs_review) do
      raw =
        Jason.encode!(%{
          "mergeable" => true,
          "verdict" => verdict,
          "checkpoint_status" => "checkpoint_ready"
        })

      assert {:ok, %{"verdict" => ^verdict}} = Advisory.classify(raw)
    end
  end

  test "plain and unrecognized JSON summaries are not advisories" do
    for raw <- [nil, "ordinary summary", Jason.encode!(%{"status" => "completed"})] do
      assert {:ok, %{"present" => false, "parse_status" => "not_present"} = advisory} =
               Advisory.classify(raw)

      assert {:ok, []} = Advisory.attention_reasons(advisory, "not_applicable")
    end
  end
end
