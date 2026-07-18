defmodule PixirMonitor.Projection.Advisory do
  @moduledoc """
  Classifies bounded model-authored summaries for both list and detail projections.

  Terminal `subagent_event` records already carry the durable summary used by the
  full Presenter fold. Keeping the syntax and advisory-only attention rules here
  prevents the parent-only Runs inventory from inventing a second interpretation or
  discarding evidence that lazy detail will later surface.
  """

  @recognized_fields ~w(mergeable checkpoint_status verdict majors minors summary)
  @constraining_gates ~w(partial failed held needs_orchestrator)
  @verdicts ~w(pass stop needs_review unknown)

  @spec classify(term()) :: {:ok, map()}
  def classify(raw) when is_binary(raw) do
    if String.starts_with?(String.trim_leading(raw), "{") do
      classify_json(raw)
    else
      {:ok, empty()}
    end
  end

  def classify(_raw), do: {:ok, empty()}

  @spec attention_reasons(map(), String.t()) :: {:ok, [String.t()]} | {:error, map()}
  def attention_reasons(advisory, gate_state) when is_map(advisory) and is_binary(gate_state) do
    reasons =
      []
      |> maybe_reason(if(advisory["verdict"] == "stop", do: "advisory_stop"))
      |> maybe_reason(if(advisory["verdict"] == "needs_review", do: "advisory_needs_review"))
      |> maybe_reason(if(gate_disagreement?(advisory, gate_state), do: "advisory_gate_disagreement"))
      |> maybe_reason(if(advisory["parse_status"] == "invalid", do: "advisory_unparseable"))

    {:ok, reasons}
  end

  def attention_reasons(_advisory, _gate_state) do
    {:error,
     %{
       kind: "invalid_advisory_attention_input",
       message: "Advisory attention requires a classified map and gate state",
       details: %{}
     }}
  end

  defp classify_json(raw) do
    case Jason.decode(raw) do
      {:ok, payload} when is_map(payload) -> {:ok, classify_payload(payload)}
      _ -> {:ok, invalid(raw)}
    end
  end

  defp classify_payload(payload) do
    if Enum.any?(@recognized_fields, &Map.has_key?(payload, &1)) do
      mergeable = if is_boolean(payload["mergeable"]), do: payload["mergeable"], else: nil
      declared = if is_binary(payload["checkpoint_status"]), do: payload["checkpoint_status"], else: nil

      verdict =
        cond do
          mergeable == false -> "stop"
          payload["verdict"] in ~w(stop needs_review) -> payload["verdict"]
          mergeable == true and declared not in @constraining_gates -> "pass"
          payload["verdict"] in @verdicts -> payload["verdict"]
          declared in @constraining_gates -> "needs_review"
          true -> "unknown"
        end

      Map.merge(empty(), %{
        "present" => true,
        "verdict" => verdict,
        "mergeable" => mergeable,
        "declared_gate" => declared,
        "parse_status" => "valid",
        "summary" => if(is_binary(payload["summary"]), do: payload["summary"], else: nil),
        "major_count" => if(is_list(payload["majors"]), do: length(payload["majors"]), else: nil),
        "minor_count" => if(is_list(payload["minors"]), do: length(payload["minors"]), else: nil)
      })
    else
      empty()
    end
  end

  defp invalid(raw) do
    empty()
    |> Map.put("present", true)
    |> Map.put("parse_status", "invalid")
    |> Map.put("raw_excerpt", String.slice(raw, 0, 4096))
  end

  defp empty do
    %{
      "present" => false,
      "verdict" => "unknown",
      "mergeable" => nil,
      "declared_gate" => nil,
      "parse_status" => "not_present",
      "summary" => nil,
      "major_count" => nil,
      "minor_count" => nil
    }
  end

  defp gate_disagreement?(advisory, gate_state) do
    advisory["present"] == true and is_binary(advisory["declared_gate"]) and
      advisory["declared_gate"] != gate_state
  end

  defp maybe_reason(reasons, nil), do: reasons
  defp maybe_reason(reasons, reason), do: reasons ++ [reason]
end
