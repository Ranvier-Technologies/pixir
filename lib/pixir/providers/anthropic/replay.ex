defmodule Pixir.Providers.Anthropic.Replay do
  @moduledoc """
  Pure replay helpers for Anthropic extended-thinking content.

  `replayable_block/2` accepts the string-keyed `data` from one canonical
  `:reasoning` Event and returns the captured raw Anthropic `thinking` or
  `redacted_thinking` block only when the event is Anthropic-dialect and was
  captured by the same model. Blocks are never normalized or rewritten; signatures
  and all other fields remain byte-identical to the Log payload.

  `assistant_content/3` is the P6 fold integration seam. It accepts one assistant
  turn's ordered History items (reasoning Events interleaved with tool_call Events
  in arrival order) and a renderer function for non-reasoning/tool positions. This
  module deliberately does not know how canonical `tool_call` Events become
  Anthropic `tool_use` blocks; P6 supplies that renderer. The renderer is called
  with each non-replayable item and may return a block, a list of blocks, or `nil`.
  """

  @type event_like :: %{optional(:type) => atom(), optional(:data) => map()}

  @doc "Return a verbatim Anthropic thinking block when dialect and model match."
  @spec replayable_block(map(), String.t()) :: {:ok, map()} | :drop
  def replayable_block(%{"dialect" => "anthropic", "model" => model, "item" => item}, model)
      when is_binary(model) and is_map(item) do
    {:ok, item}
  end

  def replayable_block(_data, _model), do: :drop

  @doc """
  Build Anthropic assistant content, preserving reasoning/tool positions.

  The renderer is required: non-reasoning items (tool_call events) must always
  be transformed by the caller (the P6 fold) — a raw canonical event is never a
  valid Anthropic content block. Envelope keys are atoms by contract, so only
  atom-keyed `:reasoning` events are recognized.
  """
  @spec assistant_content([event_like()], String.t(), (event_like() -> map() | [map()] | nil)) ::
          [map()]
  def assistant_content(items, model, render_tool_position)
      when is_list(items) and is_function(render_tool_position, 1) do
    Enum.flat_map(items, fn
      %{type: :reasoning, data: data} ->
        case replayable_block(data, model) do
          {:ok, block} -> [block]
          :drop -> []
        end

      item ->
        item
        |> render_tool_position.()
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
    end)
  end
end
