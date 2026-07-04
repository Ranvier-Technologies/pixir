defmodule Pixir.Provider.ContextWindow do
  @moduledoc """
  The conservative model context-window table and the context-pressure gauge
  (ADR 0020, "advisory before failure").

  Pressure is read from durable local evidence — the `input_tokens` field of the
  `usage_summary` already recorded per Provider call (ADR 0019) — against a
  conservative per-model window. Two rules are load-bearing:

    * **Conservative, justified values only.** The built-in table covers the model
      catalog (`Pixir.Provider.models/0`) with documented or observed per-SKU
      bounds. Large GPT-5/Codex-family models use the documented 400K total
      context window with a 272K max-*input* ceiling; `gpt-5.3-codex-spark` is a
      smaller real-time SKU with a documented 128K context window. Pixir gauges
      pressure against recorded input tokens, so the input bound is the honest
      ceiling; if a successor model is actually larger, advisories merely fire
      early (the safe direction).
    * **An unknown model never fakes a threshold.** `window_tokens/1` returns a
      structured `:context_window_unknown` error and `assess/2` degrades to an
      explicit advisory-unavailable result — no tier, no ratio, no advisory.

  Values are overrideable via `~/.pixir/config.json`:

      {"context_windows": {"gpt-5.5": 200000, "my-local-model": 32000}}

  Tiers (ADR 0020 Decision 4; boundaries are inclusive on the lower edge):
  below 70% nothing, 70–80% light advisory, 80–90% visible warning, 90%+
  recovery-eligible (`"critical"`). Reaching critical makes the session
  eligible for preflight compaction before the next Turn and for pragmatic
  recovery on low-level transport failures (e.g. WebSocket read errors) when
  the local gauge shows we were near the window. Recovery actions still record
  explicit `history_compaction` checkpoints (see ADR 0020).
  """

  # Conservative input-token ceilings for the built-in catalog (see moduledoc).
  # Spark is intentionally lower than gpt-5.3-codex: it is the real-time 128K SKU,
  # not the larger Codex model with the 400K total / 272K input bound.
  @built_in_windows %{
    "gpt-5.5" => 272_000,
    "gpt-5.4" => 272_000,
    "gpt-5.4-mini" => 272_000,
    "gpt-5.3-codex" => 272_000,
    "gpt-5.3-codex-spark" => 128_000,
    "gpt-5.2" => 272_000
  }

  @doc """
  The conservative context window (in input tokens) for `model`. Config overrides
  (`"context_windows"` in `~/.pixir/config.json`) win over the built-in table; an
  unknown model is an explicit `:context_window_unknown` error, never a guess.
  """
  @spec window_tokens(String.t() | nil) :: {:ok, pos_integer()} | {:error, map()}
  def window_tokens(model) when is_binary(model) and model != "" do
    case config_window(model) || Map.get(@built_in_windows, model) do
      tokens when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _ -> {:error, unknown_window_error(model)}
    end
  end

  def window_tokens(model), do: {:error, unknown_window_error(model)}

  @doc """
  Assess context pressure for one recorded call: `usage_summary` is the
  `Pixir.Provider.usage_summary/1` shape (atom- or string-keyed, as recorded in
  `provider_usage` evidence).

  Returns `{:ok, assessment}` where the string-keyed assessment is either

    * `"available" => true` with `"tier"` (`"none" | "advisory" | "warning" |
      "critical"`), `"ratio"`, `"input_tokens"`, and `"window_tokens"`, or
    * `"available" => false` with `"tier" => "unavailable"` and a `"reason"` —
      the unknown-model degradation; callers must fire no advisory from it.
  """
  @spec assess(map() | nil, String.t() | nil) :: {:ok, map()} | {:error, map()}
  def assess(usage_summary, model) do
    case window_tokens(model) do
      {:ok, window_tokens} ->
        input_tokens = input_tokens(usage_summary)
        ratio = input_tokens / window_tokens

        {:ok,
         %{
           "available" => true,
           "model" => model,
           "input_tokens" => input_tokens,
           "window_tokens" => window_tokens,
           "ratio" => ratio,
           "tier" => tier(ratio)
         }}

      {:error, _unknown} ->
        {:ok,
         %{
           "available" => false,
           "model" => model,
           "tier" => "unavailable",
           "reason" => "context_window_unknown"
         }}
    end
  end

  defp tier(ratio) when ratio < 0.70, do: "none"
  defp tier(ratio) when ratio < 0.80, do: "advisory"
  defp tier(ratio) when ratio < 0.90, do: "warning"
  defp tier(_ratio), do: "critical"

  defp input_tokens(%{} = summary) do
    case first_present(summary, [:input_tokens, "input_tokens"]) do
      tokens when is_integer(tokens) and tokens >= 0 -> tokens
      _ -> 0
    end
  end

  defp input_tokens(_summary), do: 0

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  # A `"context_windows"` map of model => positive integer from
  # `~/.pixir/config.json`. Invalid entries are ignored (the built-in table or the
  # explicit unknown result stands) — a malformed override must not fake a window.
  defp config_window(model) do
    case Pixir.Config.file_context_windows()[model] do
      tokens when is_integer(tokens) and tokens > 0 -> tokens
      _ -> nil
    end
  end

  defp unknown_window_error(model) do
    %{
      ok: false,
      error: %{
        kind: :context_window_unknown,
        message:
          "no conservative context window is known for model #{inspect(model)}; " <>
            "context-pressure advisories are unavailable (add a \"context_windows\" " <>
            "override to ~/.pixir/config.json to enable them)",
        details: %{model: model}
      }
    }
  end
end
