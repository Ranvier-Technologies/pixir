defmodule Pixir.Tools.Read do
  @moduledoc "Read a file from the Workspace (read-only; output is token-bounded)."

  use Pixir.Tool

  alias Pixir.Tool
  alias Pixir.Tools.Workspace

  @max_output_bytes 16_000

  @impl Pixir.Tool
  def __tool__ do
    %{
      name: "read",
      description:
        "Read a workspace file, optionally starting at a 1-indexed line offset and " <>
          "returning a bounded number of lines. Truncated and paged results include " <>
          "continuation metadata and an offset for the next read.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Workspace-relative file path"},
          "offset" => %{
            "type" => "integer",
            "minimum" => 0,
            "description" =>
              "Optional 1-indexed line to start at. Zero is accepted as the beginning and normalized to line 1."
          },
          "limit" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" =>
              "Optional positive maximum number of lines to return. Use next_offset to continue."
          }
        },
        "required" => ["path"],
        "additionalProperties" => false
      }
    }
  end

  @impl Pixir.Tool
  def execute(%{"path" => path} = args, context) when is_binary(path) do
    with :ok <- validate_args(args),
         {:ok, abs} <- Workspace.confine(context.workspace, path) do
      case File.read(abs) do
        {:ok, contents} ->
          {:ok, read_result(contents, args)}

        {:error, :enoent} ->
          {:error, Tool.error(:not_found, "file not found", %{path: path})}

        {:error, reason} ->
          {:error, Tool.error(:read_failed, "could not read file", %{path: path, reason: reason})}
      end
    end
  end

  def execute(_args, _context),
    do: {:error, Tool.error(:invalid_args, "path must be a string", %{"field" => "path"})}

  @impl Pixir.Tool
  def dry_run(%{"path" => path} = args, context) when is_binary(path) do
    with :ok <- validate_args(args),
         {:ok, abs} <- Workspace.confine(context.workspace, path) do
      {:ok,
       %{"dry_run" => true, "would" => "read", "path" => path, "exists" => File.exists?(abs)}}
    end
  end

  def dry_run(_args, _context),
    do: {:error, Tool.error(:invalid_args, "path must be a string", %{"field" => "path"})}

  defp validate_args(args) do
    with :ok <- validate_known_args(args),
         :ok <- validate_offset(Map.fetch(args, "offset")),
         :ok <- validate_limit(Map.fetch(args, "limit")) do
      :ok
    end
  end

  defp validate_known_args(args) do
    case Map.keys(args) -- ["path", "offset", "limit"] do
      [] ->
        :ok

      unknown ->
        {:error,
         Tool.error(:invalid_args, "read received unknown arguments", %{
           "unknown" => Enum.sort(unknown)
         })}
    end
  end

  defp validate_offset(:error), do: :ok
  defp validate_offset({:ok, offset}) when is_integer(offset) and offset >= 0, do: :ok

  defp validate_offset({:ok, _offset}) do
    {:error,
     Tool.error(:invalid_args, "offset must be a non-negative integer", %{
       "field" => "offset",
       "minimum" => 0
     })}
  end

  defp validate_limit(:error), do: :ok
  defp validate_limit({:ok, limit}) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit({:ok, _limit}) do
    {:error,
     Tool.error(:invalid_args, "limit must be a positive integer", %{
       "field" => "limit",
       "minimum" => 1
     })}
  end

  defp read_result(contents, args) do
    text = String.replace_invalid(contents)
    lines = split_lines(text)
    lines_total = length(lines)
    offset_effective = effective_offset(Map.get(args, "offset", 1))
    selected = select_lines(lines, offset_effective, Map.get(args, "limit"))

    {payload, lines_returned, byte_truncated?, caveat} =
      fit_output(selected, offset_effective)

    sliced? = Map.has_key?(args, "offset") or Map.has_key?(args, "limit")

    if sliced? or byte_truncated? do
      next_offset = next_offset(offset_effective, lines_returned, lines_total)

      %{
        "output" =>
          append_guidance(
            payload,
            guidance(offset_effective, lines_returned, lines_total, next_offset)
          ),
        "lines_total" => lines_total,
        "lines_returned" => lines_returned,
        "offset_effective" => offset_effective,
        "next_offset" => next_offset
      }
      |> maybe_put_caveat(caveat)
    else
      %{"output" => payload}
    end
  end

  defp effective_offset(0), do: 1
  defp effective_offset(offset), do: offset

  defp select_lines(lines, offset, nil), do: Enum.drop(lines, offset - 1)

  defp select_lines(lines, offset, limit) do
    lines
    |> Enum.drop(offset - 1)
    |> Enum.take(limit)
  end

  defp split_lines(""), do: []

  defp split_lines(text) do
    parts = String.split(text, "\n", trim: false)
    {last, leading} = List.pop_at(parts, -1)
    leading = Enum.map(leading, &(&1 <> "\n"))

    if last == "", do: leading, else: leading ++ [last]
  end

  defp fit_output(lines, offset) do
    lines
    |> Enum.reduce_while({[], 0, @max_output_bytes, false, nil}, fn line,
                                                                    {output, count, remaining,
                                                                     _truncated?, _caveat} ->
      line_bytes = byte_size(line)

      cond do
        line_bytes <= remaining ->
          {:cont, {[line | output], count + 1, remaining - line_bytes, false, nil}}

        count == 0 ->
          caveat =
            "line #{offset} exceeded the #{@max_output_bytes}-byte output ceiling and was " <>
              "truncated; continuation advances to the following line"

          {:halt, {[truncate_oversized_line(line) | output], 1, 0, true, caveat}}

        true ->
          {:halt, {output, count, remaining, true, nil}}
      end
    end)
    |> then(fn {output, count, _remaining, truncated?, caveat} ->
      {output |> Enum.reverse() |> IO.iodata_to_binary(), count, truncated?, caveat}
    end)
  end

  defp truncate_oversized_line(line) do
    marker =
      "\n…[truncated, showing up to #{@max_output_bytes} of #{byte_size(line)} bytes]"

    bounded = Tool.truncate(line, @max_output_bytes)

    if String.ends_with?(bounded, marker) do
      binary_part(bounded, 0, byte_size(bounded) - byte_size(marker))
    else
      bounded
    end
  end

  defp next_offset(offset, lines_returned, lines_total)
       when lines_returned > 0 and offset + lines_returned <= lines_total,
       do: offset + lines_returned

  defp next_offset(_offset, _lines_returned, _lines_total), do: nil

  defp guidance(offset, lines_returned, lines_total, next_offset) when lines_returned > 0 do
    last_line = offset + lines_returned - 1

    continuation =
      if is_integer(next_offset), do: "continue with offset=#{next_offset}", else: "end of file"

    "[truncated: showing lines #{offset}-#{last_line} of #{lines_total}; #{continuation}]"
  end

  defp guidance(offset, _lines_returned, lines_total, _next_offset) do
    "[truncated: showing no lines from offset #{offset} of #{lines_total}; end of file]"
  end

  defp append_guidance("", guidance), do: guidance

  defp append_guidance(payload, guidance) do
    separator = if String.ends_with?(payload, "\n"), do: "", else: "\n"
    payload <> separator <> guidance
  end

  defp maybe_put_caveat(result, nil), do: result
  defp maybe_put_caveat(result, caveat), do: Map.put(result, "continuation_caveat", caveat)
end
