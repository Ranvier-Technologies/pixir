defmodule Pixir.Provider.SSEDecoder do
  @moduledoc """
  Incremental, bounded WHATWG event-stream framing for the portable Open Responses
  HTTP/SSE profile.

  This module owns framing only. `Pixir.Provider` owns JSON reduction, strict
  `event:`/body-`type` agreement, and terminal interpretation. The decoder never
  includes payload bytes in errors or diagnostics. It is deliberately selected only
  for `open_responses`; the accepted ChatGPT/Codex compatibility reducer remains
  separate.
  """

  alias Pixir.Tool

  @max_event_bytes 16_777_216
  @bom <<0xEF, 0xBB, 0xBF>>

  @typedoc "A framed data payload. `event` is nil when no event field was supplied."
  @type frame :: %{event: String.t() | nil, data: binary(), ordinal: pos_integer()}

  @typedoc "Opaque incremental decoder state."
  @opaque t :: %__MODULE__{
            prefix: binary(),
            started?: boolean(),
            buffer: binary(),
            data_lines: [binary()],
            event: String.t() | nil,
            event_bytes: non_neg_integer(),
            ordinal: pos_integer(),
            done?: boolean(),
            failed?: boolean()
          }

  defstruct prefix: "",
            started?: false,
            buffer: "",
            data_lines: [],
            event: nil,
            event_bytes: 0,
            ordinal: 1,
            done?: false,
            failed?: false

  @doc "Maximum accepted bytes in one undecoded event, including framing."
  @spec max_event_bytes() :: pos_integer()
  def max_event_bytes, do: @max_event_bytes

  @doc "Create an empty strict decoder."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Feed one arbitrary transport chunk and return zero or more ordered frames."
  @spec feed(t(), binary()) ::
          {:ok, t(), [frame() | :done]}
          | {:error, t(), [frame() | :done], map()}
  def feed(%__MODULE__{failed?: true} = decoder, _bytes) do
    {:error, decoder, [], protocol_error(decoder, :decoder_already_failed, 0)}
  end

  def feed(%__MODULE__{} = decoder, bytes) when is_binary(bytes) do
    {decoder, released} = release_leading_bom(decoder, bytes)

    decoder
    |> append_released(released)
    |> parse_lines([])
    |> check_pending_limit()
  end

  def feed(%__MODULE__{} = decoder, _bytes) do
    decoder = %{decoder | failed?: true}
    {:error, decoder, [], protocol_error(decoder, :invalid_chunk, 0)}
  end

  @doc "Finish framing, discarding any pending non-dispatched event per WHATWG."
  @spec finish(t()) :: {:ok, t(), [frame() | :done], map()} | {:error, t(), map()}
  def finish(%__MODULE__{failed?: true} = decoder) do
    {:error, decoder, protocol_error(decoder, :decoder_already_failed, 0)}
  end

  def finish(%__MODULE__{} = decoder) do
    {decoder, released} = release_prefix_at_eof(decoder)

    with decoder <- append_released(decoder, released),
         {:ok, decoder, frames} <- parse_eof_cr(decoder),
         true <- String.valid?(decoder.buffer) do
      pending_bytes = decoder.event_bytes + byte_size(decoder.buffer)

      {:ok, reset_event(%{decoder | buffer: ""}), frames,
       %{
         done: decoder.done?,
         discarded_pending:
           pending_bytes > 0 or decoder.data_lines != [] or not is_nil(decoder.event),
         discarded_bytes: pending_bytes
       }}
    else
      false ->
        decoder = %{decoder | failed?: true}
        {:error, decoder, protocol_error(decoder, :invalid_utf8, pending_observed(decoder))}

      {:error, %__MODULE__{} = decoder, _frames, error} ->
        {:error, decoder, error}
    end
  end

  defp release_leading_bom(%__MODULE__{started?: true} = decoder, bytes),
    do: {decoder, bytes}

  defp release_leading_bom(%__MODULE__{} = decoder, bytes) do
    candidate = decoder.prefix <> bytes

    cond do
      candidate == "" ->
        {decoder, ""}

      byte_size(candidate) < byte_size(@bom) and bom_prefix?(candidate) ->
        {%{decoder | prefix: candidate}, ""}

      String.starts_with?(candidate, @bom) ->
        <<_bom::binary-size(3), rest::binary>> = candidate
        {%{decoder | prefix: "", started?: true}, rest}

      true ->
        {%{decoder | prefix: "", started?: true}, candidate}
    end
  end

  defp release_prefix_at_eof(%__MODULE__{started?: true} = decoder),
    do: {decoder, ""}

  defp release_prefix_at_eof(%__MODULE__{prefix: @bom} = decoder),
    do: {%{decoder | prefix: "", started?: true}, ""}

  defp release_prefix_at_eof(%__MODULE__{} = decoder),
    do: {%{decoder | prefix: "", started?: true}, decoder.prefix}

  defp bom_prefix?(candidate) do
    prefix_size = byte_size(candidate)
    binary_part(@bom, 0, prefix_size) == candidate
  end

  defp append_released(decoder, ""), do: decoder
  defp append_released(decoder, released), do: %{decoder | buffer: decoder.buffer <> released}

  defp parse_lines(%__MODULE__{} = decoder, frames) do
    case next_line(decoder.buffer) do
      :pending ->
        {:ok, decoder, Enum.reverse(frames)}

      {:line, line, delimiter_bytes, rest} ->
        observed = decoder.event_bytes + byte_size(line) + delimiter_bytes

        cond do
          observed > @max_event_bytes ->
            fail(decoder, frames, :event_too_large, observed)

          not String.valid?(line) ->
            fail(decoder, frames, :invalid_utf8, observed)

          true ->
            decoder = %{decoder | buffer: rest, event_bytes: observed}

            case consume_line(decoder, line) do
              {:ok, decoder, nil} -> parse_lines(decoder, frames)
              {:ok, decoder, frame} -> parse_lines(decoder, [frame | frames])
              {:error, decoder, reason} -> fail(decoder, frames, reason, observed)
            end
        end
    end
  end

  defp next_line(buffer) do
    case :binary.match(buffer, ["\r", "\n"]) do
      :nomatch ->
        :pending

      {position, 1} ->
        <<line::binary-size(^position), delimiter, rest::binary>> = buffer

        case {delimiter, rest} do
          {?\r, ""} ->
            :pending

          {?\r, <<?\n, tail::binary>>} ->
            {:line, line, 2, tail}

          _ ->
            {:line, line, 1, rest}
        end
    end
  end

  defp parse_eof_cr(%__MODULE__{buffer: buffer} = decoder) do
    if String.ends_with?(buffer, "\r") do
      line_size = byte_size(buffer) - 1
      <<line::binary-size(^line_size), ?\r>> = buffer
      observed = decoder.event_bytes + byte_size(line) + 1

      cond do
        observed > @max_event_bytes ->
          fail(decoder, [], :event_too_large, observed)

        not String.valid?(line) ->
          fail(decoder, [], :invalid_utf8, observed)

        true ->
          decoder = %{decoder | buffer: "", event_bytes: observed}

          case consume_line(decoder, line) do
            {:ok, decoder, nil} -> {:ok, decoder, []}
            {:ok, decoder, frame} -> {:ok, decoder, [frame]}
            {:error, decoder, reason} -> fail(decoder, [], reason, observed)
          end
      end
    else
      {:ok, decoder, []}
    end
  end

  defp check_pending_limit({:error, _decoder, _frames, _error} = result), do: result

  defp check_pending_limit({:ok, decoder, frames}) do
    observed = pending_observed(decoder)

    if observed <= @max_event_bytes,
      do: {:ok, decoder, frames},
      else: fail(decoder, Enum.reverse(frames), :event_too_large, observed)
  end

  defp pending_observed(decoder), do: decoder.event_bytes + byte_size(decoder.buffer)

  defp consume_line(%__MODULE__{done?: true} = decoder, ""),
    do: {:ok, reset_event(decoder), nil}

  defp consume_line(%__MODULE__{done?: true} = decoder, <<?:, _rest::binary>>),
    do: {:ok, decoder, nil}

  defp consume_line(%__MODULE__{done?: true} = decoder, line) do
    case field(line) do
      {name, _value} when name in ["data", "event"] ->
        {:error, decoder, :event_after_done}

      _unknown ->
        {:ok, decoder, nil}
    end
  end

  defp consume_line(decoder, "") do
    case Enum.reverse(decoder.data_lines) do
      [] ->
        {:ok, reset_event(decoder), nil}

      data_lines ->
        payload = Enum.join(data_lines, "\n")
        ordinal = decoder.ordinal
        event = decoder.event
        decoder = reset_event(%{decoder | ordinal: ordinal + 1})

        if payload == "[DONE]" do
          {:ok, %{decoder | done?: true}, :done}
        else
          {:ok, decoder, %{event: event, data: payload, ordinal: ordinal}}
        end
    end
  end

  defp consume_line(decoder, <<?:, _rest::binary>>), do: {:ok, decoder, nil}

  defp consume_line(decoder, line) do
    case field(line) do
      {"data", value} -> {:ok, %{decoder | data_lines: [value | decoder.data_lines]}, nil}
      {"event", value} -> {:ok, %{decoder | event: value}, nil}
      _unknown -> {:ok, decoder, nil}
    end
  end

  defp field(line) do
    case :binary.match(line, ":") do
      :nomatch ->
        {line, ""}

      {position, 1} ->
        <<name::binary-size(^position), ?:, value::binary>> = line
        {name, strip_one_space(value)}
    end
  end

  defp strip_one_space(<<?\s, rest::binary>>), do: rest
  defp strip_one_space(value), do: value

  defp reset_event(decoder) do
    %{decoder | data_lines: [], event: nil, event_bytes: 0}
  end

  defp fail(decoder, frames, reason, observed) do
    decoder = %{decoder | failed?: true}
    {:error, decoder, Enum.reverse(frames), protocol_error(decoder, reason, observed)}
  end

  defp protocol_error(decoder, reason, observed) do
    Tool.error(:invalid_response, "The Open Responses event stream framing was invalid.", %{
      reason: reason,
      ordinal: decoder.ordinal,
      observed_bytes: observed,
      limit: @max_event_bytes
    })
  end
end
