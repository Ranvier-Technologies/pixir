defmodule Pixir.Providers.ErrBody do
  @moduledoc """
  Shared bounded error-body capture for provider transports.

  Issue #268 item 1 keeps the cap in one place so OpenAI and Anthropic transports
  cannot drift in how much non-2xx response body they retain before classification.
  """

  @max_bytes 16_384

  @doc "Maximum number of error-body bytes retained before classification."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Append bytes while retaining at most `max_bytes/0`."
  @spec append(binary(), binary()) :: binary()
  def append(current, data) when is_binary(current) and is_binary(data) do
    remaining = @max_bytes - min(byte_size(current), @max_bytes)

    cond do
      remaining <= 0 ->
        binary_part(current, 0, @max_bytes)

      byte_size(data) <= remaining ->
        current <> data

      true ->
        # Defensive capture is byte-bounded; UTF-8 graphemes may be split.
        current <> binary_part(data, 0, remaining)
    end
  end

  @doc "Whether the captured body is at the truncation marker threshold."
  @spec truncated?(binary()) :: boolean()
  def truncated?(body) when is_binary(body) do
    # Exact-boundary captures are marked truncated because the capped body carries
    # no evidence that the upstream body ended at the same byte.
    byte_size(body) >= @max_bytes
  end
end
