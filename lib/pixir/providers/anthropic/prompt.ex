defmodule Pixir.Providers.Anthropic.Prompt do
  @moduledoc """
  Provider-private pa1 prompt builder for Anthropic Messages requests.

  pa1 mirrors the px3 prompt contract in doctrine, not bytes. Layer 0 is a
  byte-stable system text block selected by mode, Layer 1 is the deterministic
  Skills index when present, and volatile late context is inserted as the leading
  text content block of the latest user message because Anthropic has no developer
  role on the target model.

  cache_control planning is fixed for pa1:

    * B1 is placed on the last system block.
    * B2 is placed on the content block at `prev_turn_boundary`, using a 1-based
      count over message content blocks after any late-context insertion. If that
      block is not cacheable, B2 walks backward to the nearest cacheable block at
      a lower position and is omitted when none exists.
    * B3 is placed only when more than 15 content blocks exist between the prior
      message breakpoint position, or B1 when B2 is absent, and the latest user
      message. When triggered, B3 targets the last content block before the latest
      user message, then walks backward to the nearest cacheable block at or
      before that target and is omitted when none exists or when it collides with
      B2.

  Verified Anthropic prompt-caching documentation on 2026-07-08 says thinking,
  redacted_thinking, and empty text blocks cannot be marked directly with
  cache_control; pa1 treats those blocks as non-cacheable.

  pa1 never emits more than three breakpoints. The fourth Anthropic breakpoint is
  reserved by ADR 0037 and adding a planned use for it requires a pa1 to pa2
  prompt contract bump. Any future layout or fence-token change is also a pa1 to
  pa2 bump.
  """

  alias Pixir.Tool

  @prompt_contract_version "pa1"
  @cache_control %{"type" => "ephemeral"}
  @hash_bytes 8
  @b3_threshold 15
  @late_context_open "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>"
  @late_context_close "<<<END_PIXIR_PA1_LATE_CONTEXT>>>"

  @repo_instructions """
  Repository instructions: projects may contain one or more AGENTS.md files. Before
  making or reviewing code changes, inspect the relevant instructions with read or
  bash. Start at the workspace root, then read the nearest AGENTS.md for directories
  you touch. In monorepos, local instructions override broader ones for their
  subtree. Do not rely on stale remembered instructions when the file can be read.
  """

  @checkpoint_contract """
  Compacted history: if a "Compressed session memory" checkpoint appears in the
  conversation, treat it as lossy older context. Recent messages and the current
  request override stale checkpoint intent; the full session log remains
  authoritative outside the conversation.
  """

  @layer0_tail String.trim(@repo_instructions) <> "\n\n" <> String.trim(@checkpoint_contract)

  @plan_layer0 String.trim("""
               You are Pixir, a terminal coding agent.
               You are in PLAN MODE: investigate with read-only tools (read, and safe shell
               commands like grep/ls) and produce a clear, step-by-step plan. Do NOT modify
               files or run mutating commands; write/edit and unsafe shell are disabled in
               this mode and will be refused. Call the `update_plan` tool to record the plan
               as a checklist, then STOP and let the user review it. They will switch to
               build mode and re-prompt to execute. All paths are relative to the workspace;
               a fenced context block at the start of the latest user message identifies the
               workspace root.

               #{@layer0_tail}
               """)

  @build_layer0 String.trim("""
                You are Pixir, a terminal coding agent.
                Use the tools (read, write, bash) to inspect and change files and run commands.
                All paths are relative to the workspace; a fenced context block at the start of
                the latest user message identifies the workspace root. Prefer taking actions
                with tools over describing them, work step by step, and end with a concise
                summary of what you did.

                #{@layer0_tail}
                """)

  @type input :: %{
          required(:mode) => :build | :plan,
          required(:skills_index) => String.t() | nil,
          required(:messages) => [map()],
          required(:late_context) => String.t() | nil,
          required(:prev_turn_boundary) => non_neg_integer() | nil
        }

  @doc "The pa1 prompt contract label, mirrored into neutral cache metadata (ADR 0037 D7)."
  @spec prompt_contract_version() :: String.t()
  def prompt_contract_version, do: @prompt_contract_version

  @doc "Build Anthropic-native system and messages with the pa1 cache plan."
  @spec build(input()) :: {:ok, map()} | {:error, map()}
  def build(input) when is_map(input) do
    with {:ok, mode} <- mode(Map.get(input, :mode) || Map.get(input, "mode")),
         {:ok, skills_index} <- optional_string(input, :skills_index),
         {:ok, messages} <- messages(input),
         {:ok, late_context} <- optional_string(input, :late_context),
         {:ok, prev_turn_boundary} <- prev_turn_boundary(input) do
      layer0 = layer0(mode)

      system =
        layer0
        |> system_blocks(skills_index)
        |> put_b1()

      messages =
        messages
        |> normalize_messages()
        |> maybe_prepend_late_context(late_context)

      {messages, breakpoints} = plan_message_breakpoints(messages, prev_turn_boundary)

      breakpoints = ["B1" | breakpoints]

      {:ok,
       %{
         system: system,
         messages: messages,
         contract: %{
           "prompt_contract_version" => @prompt_contract_version,
           "breakpoints" => breakpoints,
           "layer0_hash" => stable_hash!(layer0)
         }
       }}
    end
  end

  def build(_input) do
    {:error,
     Tool.error(:invalid_args, "Anthropic prompt build/1 requires an input map.", %{
       expected: "map"
     })}
  end

  defp mode(:build), do: {:ok, :build}
  defp mode(:plan), do: {:ok, :plan}

  defp mode(other) do
    {:error,
     Tool.error(:invalid_args, "Anthropic prompt mode is not supported.", %{
       field: :mode,
       supported: ["build", "plan"],
       received: inspect(other)
     })}
  end

  defp optional_string(input, field) do
    case Map.get(input, field) || Map.get(input, Atom.to_string(field)) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        {:ok, value}

      value ->
        {:error,
         Tool.error(:invalid_args, "Anthropic prompt field must be a string or nil.", %{
           field: field,
           received: inspect(value)
         })}
    end
  end

  defp messages(input) do
    case Map.get(input, :messages) || Map.get(input, "messages") do
      messages when is_list(messages) ->
        if Enum.all?(messages, &is_map/1) do
          {:ok, messages}
        else
          {:error,
           Tool.error(:invalid_args, "Anthropic prompt messages must be a list of maps.", %{
             field: :messages
           })}
        end

      other ->
        {:error,
         Tool.error(:invalid_args, "Anthropic prompt messages must be a list of maps.", %{
           field: :messages,
           received: inspect(other)
         })}
    end
  end

  defp prev_turn_boundary(input) do
    case Map.get(input, :prev_turn_boundary) || Map.get(input, "prev_turn_boundary") do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      value ->
        {:error,
         Tool.error(
           :invalid_args,
           "Anthropic prompt prev_turn_boundary must be nil or non-negative integer.",
           %{
             field: :prev_turn_boundary,
             received: inspect(value)
           }
         )}
    end
  end

  defp layer0(:plan), do: @plan_layer0
  defp layer0(:build), do: @build_layer0

  defp system_blocks(layer0, nil), do: [%{"type" => "text", "text" => layer0}]

  defp system_blocks(layer0, skills_index),
    do: [%{"type" => "text", "text" => layer0}, %{"type" => "text", "text" => skills_index}]

  defp put_b1(system) do
    List.update_at(system, -1, &put_cache_control/1)
  end

  defp normalize_messages(messages) do
    Enum.map(messages, fn message ->
      Map.put(message, "content", normalize_content(Map.get(message, "content")))
    end)
  end

  defp normalize_content(content) when is_binary(content),
    do: [%{"type" => "text", "text" => content}]

  defp normalize_content(content) when is_list(content), do: content
  defp normalize_content(nil), do: []
  defp normalize_content(other), do: [%{"type" => "text", "text" => to_string(other)}]

  defp maybe_prepend_late_context(messages, nil), do: messages

  defp maybe_prepend_late_context(messages, late_context) do
    index = latest_user_index(messages)

    if is_nil(index) do
      messages
    else
      List.update_at(messages, index, fn message ->
        content = Map.get(message, "content", [])
        Map.put(message, "content", [late_context_block(late_context) | content])
      end)
    end
  end

  defp latest_user_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {message, index} ->
      if Map.get(message, "role") == "user", do: index
    end)
  end

  defp late_context_block(late_context) do
    %{
      "type" => "text",
      "text" => @late_context_open <> "\n" <> late_context <> "\n" <> @late_context_close
    }
  end

  defp plan_message_breakpoints(messages, prev_turn_boundary) do
    latest_user_start = latest_user_start_position(messages)

    {messages, b2_labels, b2_position} =
      maybe_put_b2(messages, prev_turn_boundary, latest_user_start)

    {messages, b3_labels} =
      maybe_put_b3(messages, prev_turn_boundary, latest_user_start, b2_position)

    {messages, b2_labels ++ b3_labels}
  end

  defp maybe_put_b2(messages, nil, _latest_user_start), do: {messages, [], nil}
  defp maybe_put_b2(messages, 0, _latest_user_start), do: {messages, [], nil}

  # B2 marks the last block of the folded history as of the previous turn. A
  # boundary at or past the latest user message would cache the current request
  # itself; that is caller error and the breakpoint is honestly omitted.
  defp maybe_put_b2(messages, position, latest_user_start) when position >= latest_user_start,
    do: {messages, [], nil}

  defp maybe_put_b2(messages, position, _latest_user_start) do
    case put_cache_at_or_before_content_position(messages, position) do
      {:ok, messages, position} -> {messages, ["B2"], position}
      :error -> {messages, [], nil}
    end
  end

  defp maybe_put_b3(messages, prev_turn_boundary, latest_user_start, b2_position) do
    boundary = prev_turn_boundary || 0
    target = latest_user_start - 1

    if target > 0 and target - boundary > @b3_threshold do
      case put_cache_at_or_before_content_position(messages, target) do
        {:ok, messages, ^b2_position} -> {messages, []}
        {:ok, messages, _position} -> {messages, ["B3"]}
        :error -> {messages, []}
      end
    else
      {messages, []}
    end
  end

  defp latest_user_start_position(messages) do
    latest_index = latest_user_index(messages)

    messages
    |> Enum.with_index()
    |> Enum.reduce_while(1, fn {message, index}, position ->
      if index == latest_index do
        {:halt, position}
      else
        {:cont, position + length(Map.get(message, "content", []))}
      end
    end)
  end

  defp put_cache_at_or_before_content_position(messages, position) do
    case cacheable_position_at_or_before(messages, position) do
      nil ->
        :error

      cacheable_position ->
        case put_cache_at_content_position(messages, cacheable_position) do
          {:ok, messages} -> {:ok, messages, cacheable_position}
          :error -> :error
        end
    end
  end

  defp cacheable_position_at_or_before(messages, target) do
    messages
    |> Enum.flat_map(&Map.get(&1, "content", []))
    |> Enum.with_index(1)
    |> Enum.filter(fn {block, position} -> position <= target and cacheable_block?(block) end)
    |> List.last()
    |> case do
      {_block, position} -> position
      nil -> nil
    end
  end

  defp cacheable_block?(%{"type" => "thinking"}), do: false
  defp cacheable_block?(%{"type" => "redacted_thinking"}), do: false
  defp cacheable_block?(%{"type" => "text", "text" => ""}), do: false
  defp cacheable_block?(%{"type" => "text", "text" => text}) when is_binary(text), do: true
  defp cacheable_block?(%{"type" => "text"}), do: false
  defp cacheable_block?(block) when is_map(block), do: true
  defp cacheable_block?(_block), do: false

  defp put_cache_at_content_position(messages, position) do
    {messages, found?, _next} =
      Enum.reduce(messages, {[], false, 1}, fn message, {acc, found?, next} ->
        cond do
          found? ->
            {[message | acc], true, next + length(Map.get(message, "content", []))}

          true ->
            content = Map.get(message, "content", [])
            count = length(content)

            if position >= next and position < next + count do
              index = position - next

              message =
                Map.put(message, "content", List.update_at(content, index, &put_cache_control/1))

              {[message | acc], true, next + count}
            else
              {[message | acc], false, next + count}
            end
        end
      end)

    if found?, do: {:ok, Enum.reverse(messages)}, else: :error
  end

  defp put_cache_control(block) when is_map(block),
    do: Map.put(block, "cache_control", @cache_control)

  defp put_cache_control(block),
    do: %{"type" => "text", "text" => to_string(block), "cache_control" => @cache_control}

  defp stable_hash!(term) do
    term
    |> stable_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_bytes * 2)
  end

  defp stable_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stable_term(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp stable_term(list) when is_list(list), do: Enum.map(list, &stable_term/1)
  defp stable_term(value), do: value
end
