defmodule Pixir.SessionId do
  @moduledoc """
  Canonical validation for Pixir Session identifiers.

  Session ids become Registry keys, filename components, recovery-command arguments,
  and durable evidence references. This module is therefore the only grammar authority:
  callers validate before any Registry lookup, path construction, filesystem operation,
  command rendering, or Provider projection.

  Valid ids are 1..235 bytes of valid UTF-8. The first codepoint is a Unicode letter,
  number, or underscore; later codepoints may additionally be Unicode combining marks,
  hyphens, or dots. The 235-byte ceiling leaves room for Pixir's longest generated Log
  suffix, `.ndjson.tmp-<8 hex>`, inside a 255-byte filename component.

  Invalid-id errors deliberately never echo, normalize, decode, clean, or basename-reduce
  the caller's value. The stable `reason` and bounded metadata are sufficient for agents
  and presenters to correct the input without reflecting hostile content.
  """

  alias Pixir.Tool

  @max_bytes 235
  @grammar ~r/\A[\p{L}\p{N}_][\p{L}\p{N}\p{M}_.-]*\z/u

  @type reason ::
          :not_string
          | :empty
          | :invalid_utf8
          | :too_long
          | :invalid_start
          | :invalid_character

  @doc "Maximum accepted UTF-8 byte length for a Session id."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Validate a Session id without returning or echoing the supplied value."
  @spec validate(term()) :: :ok | {:error, map()}
  def validate(value) do
    case invalid_reason(value) do
      nil -> :ok
      reason -> {:error, invalid_error(reason, value)}
    end
  end

  @doc "Whether a value satisfies the canonical Session-id grammar."
  @spec valid?(term()) :: boolean()
  def valid?(value), do: is_nil(invalid_reason(value))

  defp invalid_reason(value) when not is_binary(value), do: :not_string
  defp invalid_reason(""), do: :empty
  defp invalid_reason(value) when byte_size(value) > @max_bytes, do: :too_long

  defp invalid_reason(value) do
    cond do
      not String.valid?(value) ->
        :invalid_utf8

      Regex.match?(@grammar, value) ->
        nil

      valid_start?(value) ->
        :invalid_character

      true ->
        :invalid_start
    end
  end

  defp valid_start?(value) do
    case String.next_codepoint(value) do
      {first, _rest} -> Regex.match?(~r/\A[\p{L}\p{N}_]\z/u, first)
      nil -> false
    end
  end

  defp invalid_error(reason, value) do
    details =
      %{
        "field" => "session_id",
        "reason" => Atom.to_string(reason),
        "max_bytes" => @max_bytes,
        "next_actions" => ["pass_a_valid_session_id"]
      }
      |> maybe_put_observed_bytes(value)

    Tool.error(:invalid_args, "session id is invalid", details)
  end

  defp maybe_put_observed_bytes(details, value) when is_binary(value),
    do: Map.put(details, "observed_bytes", byte_size(value))

  defp maybe_put_observed_bytes(details, _value), do: details
end
