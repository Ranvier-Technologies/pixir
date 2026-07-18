defmodule Pixir.Providers.ErrBody do
  @moduledoc """
  Shared bounded error-body capture for every current consumer.

  Issue #268 item 1 keeps the cap in one place. Issue #306 adds explicit drop
  provenance for OpenAI, Anthropic, and ModelsRefresh so an exactly-full body is
  distinct from one whose trailing bytes were discarded.
  """

  @max_bytes 16_384

  defstruct body: "", dropped?: false

  @opaque t :: %__MODULE__{body: binary(), dropped?: boolean()}

  @doc "Maximum number of error-body bytes retained before classification."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Create an empty bounded capture with no discarded-byte evidence."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Append bytes while retaining at most `max_bytes/0` and recording any drop."
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{body: current, dropped?: dropped?} = capture, data)
      when is_binary(data) do
    remaining = @max_bytes - byte_size(current)

    cond do
      remaining <= 0 ->
        %{capture | dropped?: dropped? or data != ""}

      byte_size(data) <= remaining ->
        %{capture | body: current <> data}

      true ->
        # Defensive capture is byte-bounded; UTF-8 graphemes may be split.
        %{capture | body: current <> binary_part(data, 0, remaining), dropped?: true}
    end
  end

  @doc "Return the retained body bytes for classification or bounded diagnostics."
  @spec body(t()) :: binary()
  def body(%__MODULE__{body: body}), do: body

  @doc "Whether at least one received byte was discarded from this capture."
  @spec truncated?(t()) :: boolean()
  def truncated?(%__MODULE__{dropped?: dropped?}), do: dropped?
end
