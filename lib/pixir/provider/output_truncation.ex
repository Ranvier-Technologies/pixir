defmodule Pixir.Provider.OutputTruncation do
  @moduledoc """
  Provider-neutral evidence about whether a successful model response ended because
  the Provider truncated its output.

  The value is deliberately independent from operational `finish_reason`: a response
  can contain executable, finalized tool calls and still be positively truncated. Raw
  Provider terminal tokens are retained only when they are bounded, valid UTF-8, and
  contain the conservative identity alphabet used by this contract.

  Missing and malformed historical evidence normalizes to an explicit `:unknown`
  value. It is never inferred from token counts, text length, transport closure, or a
  requested output cap.
  """

  @positive_reasons ~w(provider_output_limit provider_context_window_limit provider_content_filter)a
  @unknown_reasons ~w(missing_terminal_evidence unrecognized_terminal_reason provider_did_not_report historical_evidence_absent invalid_evidence)a
  @statuses ~w(not_truncated truncated unknown)a
  @token_re ~r/\A[A-Za-z0-9_.:-]+\z/

  @enforce_keys [:status, :reason, :provider_reason]
  defstruct [:status, :reason, :provider_reason]

  @opaque t :: %__MODULE__{
            status: :not_truncated | :truncated | :unknown,
            reason: atom() | nil,
            provider_reason: String.t() | nil
          }

  @doc "Build explicit Provider evidence that output was not truncated."
  @spec not_truncated(term()) :: t()
  def not_truncated(provider_reason) do
    case safe_token(provider_reason) do
      {:ok, token} -> value(:not_truncated, nil, token)
      :error -> invalid()
    end
  end

  @doc "Build explicit positive truncation evidence."
  @spec truncated(term(), term()) :: t()
  def truncated(reason, provider_reason) do
    with {:ok, reason} <- enum(reason, @positive_reasons),
         {:ok, token} <- safe_token(provider_reason) do
      value(:truncated, reason, token)
    else
      _ -> invalid()
    end
  end

  @doc "Build explicit uncertainty evidence."
  @spec unknown(term(), term()) :: t()
  def unknown(reason, provider_reason \\ nil) do
    with {:ok, reason} <- enum(reason, @unknown_reasons),
         {:ok, token} <- optional_safe_token(provider_reason) do
      value(:unknown, reason, token)
    else
      _ -> invalid()
    end
  end

  @doc "Normalize a struct or atom/string-keyed neutral evidence map."
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = evidence) do
    normalize(%{
      status: evidence.status,
      reason: evidence.reason,
      provider_reason: evidence.provider_reason
    })
  end

  def normalize(map) when is_map(map) and not is_struct(map) do
    if duplicate_known_keys?(map) do
      invalid()
    else
      status = known(map, :status)
      reason = known(map, :reason)
      provider_reason = known(map, :provider_reason)

      case enum(status, @statuses) do
        {:ok, :not_truncated} when is_nil(reason) -> not_truncated(provider_reason)
        {:ok, :truncated} -> truncated(reason, provider_reason)
        {:ok, :unknown} -> unknown(reason, provider_reason)
        _ -> invalid()
      end
    end
  end

  def normalize(_term), do: invalid()

  @doc "Normalize the evidence carried by one successful Provider result."
  @spec from_result(term(), module()) :: t()
  def from_result(result, provider_module) when is_map(result) do
    case fetch_unique(result, :output_truncation) do
      {:ok, evidence} -> normalize(evidence)
      :duplicate -> invalid()
      :missing -> legacy_or_missing(result, provider_module)
    end
  end

  def from_result(_result, _provider_module), do: unknown(:provider_did_not_report)

  @doc "Normalize the nested object in canonical `provider_usage` data."
  @spec from_event_data(term()) :: t()
  def from_event_data(data) when is_map(data) do
    case fetch_unique(data, :output_truncation) do
      {:ok, evidence} -> normalize(evidence)
      :duplicate -> invalid()
      :missing -> legacy_event_or_historical(data)
    end
  end

  def from_event_data(_data), do: unknown(:historical_evidence_absent)

  @doc "Project the opaque value into an atom-keyed Provider result map."
  @spec to_result_map(t() | term()) :: map()
  def to_result_map(evidence) do
    evidence = normalize(evidence)

    %{status: evidence.status, reason: evidence.reason, provider_reason: evidence.provider_reason}
    |> reject_nil()
  end

  @doc "Project the opaque value into a string-keyed canonical Event map."
  @spec to_event_data(t() | term()) :: map()
  def to_event_data(evidence) do
    evidence = normalize(evidence)

    %{
      "status" => Atom.to_string(evidence.status),
      "reason" => enum_string(evidence.reason),
      "provider_reason" => evidence.provider_reason
    }
    |> reject_nil()
  end

  @doc "Return the neutral status enum."
  @spec status(t() | term()) :: atom()
  def status(evidence), do: normalize(evidence).status

  @doc "Return the neutral reason enum, if any."
  @spec reason(t() | term()) :: atom() | nil
  def reason(evidence), do: normalize(evidence).reason

  @doc "Return the bounded raw Provider terminal token, if retained."
  @spec provider_reason(t() | term()) :: String.t() | nil
  def provider_reason(evidence), do: normalize(evidence).provider_reason

  @doc "True only for explicit, valid positive truncation evidence."
  @spec truncated?(t() | term()) :: boolean()
  def truncated?(evidence), do: status(evidence) == :truncated

  @doc "Return a bounded redacted summary that never includes the raw Provider token."
  @spec summary(t() | term()) :: String.t()
  def summary(evidence) do
    evidence = normalize(evidence)

    "#Pixir.Provider.OutputTruncation<status=#{evidence.status}, reason=#{evidence.reason || :none}>"
  end

  defimpl Inspect do
    import Inspect.Algebra
    def inspect(value, _opts), do: concat([Pixir.Provider.OutputTruncation.summary(value)])
  end

  defp legacy_or_missing(result, Pixir.Providers.Anthropic) do
    metadata = Map.get(result, :provider_metadata, Map.get(result, "provider_metadata", %{}))
    legacy_anthropic(metadata, :provider_did_not_report)
  end

  defp legacy_or_missing(_result, _provider_module), do: unknown(:provider_did_not_report)

  defp legacy_event_or_historical(data) do
    metadata = Map.get(data, "provider_metadata", Map.get(data, :provider_metadata, data))
    legacy_anthropic(metadata, :historical_evidence_absent)
  end

  defp legacy_anthropic(metadata, fallback) when is_map(metadata) do
    truncated = Map.get(metadata, "truncated", Map.get(metadata, :truncated))
    reason = Map.get(metadata, "stop_reason", Map.get(metadata, :stop_reason))

    case {truncated, reason} do
      {true, "max_tokens"} ->
        truncated(:provider_output_limit, "max_tokens")

      {true, :max_tokens} ->
        truncated(:provider_output_limit, "max_tokens")

      {true, "model_context_window_exceeded"} ->
        truncated(:provider_context_window_limit, "model_context_window_exceeded")

      {true, :model_context_window_exceeded} ->
        truncated(:provider_context_window_limit, "model_context_window_exceeded")

      _ ->
        unknown(fallback)
    end
  end

  defp legacy_anthropic(_metadata, fallback), do: unknown(fallback)

  defp duplicate_known_keys?(map) do
    Enum.any?([:status, :reason, :provider_reason], fn key ->
      Map.has_key?(map, key) and Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp fetch_unique(map, key) do
    atom? = Map.has_key?(map, key)
    string? = Map.has_key?(map, Atom.to_string(key))

    case {atom?, string?} do
      {true, true} -> :duplicate
      {true, false} -> {:ok, Map.fetch!(map, key)}
      {false, true} -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      {false, false} -> :missing
    end
  end

  defp known(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp enum(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: :error
  end

  defp enum(value, allowed) when is_binary(value) do
    Enum.find_value(allowed, :error, fn candidate ->
      if Atom.to_string(candidate) == value, do: {:ok, candidate}, else: false
    end)
  end

  defp enum(_value, _allowed), do: :error

  defp safe_token(token) when is_binary(token) do
    if String.valid?(token) and byte_size(token) in 1..64 and Regex.match?(@token_re, token) do
      {:ok, token}
    else
      :error
    end
  end

  defp safe_token(_token), do: :error

  defp optional_safe_token(nil), do: {:ok, nil}
  defp optional_safe_token(token), do: safe_token(token)

  defp invalid, do: value(:unknown, :invalid_evidence, nil)

  defp value(status, reason, token),
    do: %__MODULE__{status: status, reason: reason, provider_reason: token}

  defp enum_string(nil), do: nil
  defp enum_string(value), do: Atom.to_string(value)
  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
