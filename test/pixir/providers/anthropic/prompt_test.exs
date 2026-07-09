defmodule Pixir.Providers.Anthropic.PromptTest do
  use ExUnit.Case, async: true

  alias Pixir.Providers.Anthropic.Prompt

  @shared_tail """
               Repository instructions: projects may contain one or more AGENTS.md files. Before
               making or reviewing code changes, inspect the relevant instructions with read or
               bash. Start at the workspace root, then read the nearest AGENTS.md for directories
               you touch. In monorepos, local instructions override broader ones for their
               subtree. Do not rely on stale remembered instructions when the file can be read.

               Compacted history: if a "Compressed session memory" checkpoint appears in the
               conversation, treat it as lossy older context. Recent messages and the current
               request override stale checkpoint intent; the full session log remains
               authoritative outside the conversation.
               """
               |> String.trim()

  defp input(overrides \\ %{}) do
    Map.merge(
      %{
        mode: :build,
        skills_index: "skill index",
        messages: [user("hello")],
        late_context: nil,
        prev_turn_boundary: nil
      },
      overrides
    )
  end

  defp user(text), do: %{"role" => "user", "content" => text}
  defp assistant(text), do: %{"role" => "assistant", "content" => text}
  defp user_blocks(blocks), do: %{"role" => "user", "content" => blocks}
  defp text(n), do: %{"type" => "text", "text" => "block #{n}"}
  defp empty_text, do: %{"type" => "text", "text" => ""}

  defp thinking(n),
    do: %{"type" => "thinking", "thinking" => "thought #{n}", "signature" => "sig#{n}"}

  defp redacted(n), do: %{"type" => "redacted_thinking", "data" => "redacted #{n}"}

  defp message_breakpoints(messages) do
    messages
    |> Enum.flat_map(&Map.get(&1, "content", []))
    |> Enum.with_index(1)
    |> Enum.filter(fn {block, _index} -> Map.has_key?(block, "cache_control") end)
  end

  defp all_breakpoint_count(%{system: system, messages: messages}) do
    system_count = Enum.count(system, &Map.has_key?(&1, "cache_control"))
    message_count = length(message_breakpoints(messages))
    system_count + message_count
  end

  test "byte-stability and shared layer 0 tail" do
    args = input()

    assert {:ok, first} = Prompt.build(args)
    assert {:ok, second} = Prompt.build(args)

    assert first.system == second.system
    assert first.messages == second.messages
    assert first.contract == second.contract

    assert {:ok, plan} = Prompt.build(input(%{mode: :plan}))
    assert {:ok, build} = Prompt.build(input(%{mode: :build}))

    plan_layer0 = hd(plan.system)["text"]
    build_layer0 = hd(build.system)["text"]

    assert String.contains?(plan_layer0, @shared_tail)
    assert String.contains?(build_layer0, @shared_tail)
    assert String.split(plan_layer0, @shared_tail) |> length() == 2
    assert String.split(build_layer0, @shared_tail) |> length() == 2
  end

  test "B1 lands on the last system block and is the only system breakpoint" do
    assert {:ok, with_skills} = Prompt.build(input(%{skills_index: "skills"}))

    assert length(with_skills.system) == 2
    refute Map.has_key?(Enum.at(with_skills.system, 0), "cache_control")
    assert Enum.at(with_skills.system, 1)["cache_control"] == %{"type" => "ephemeral"}

    assert {:ok, no_skills} = Prompt.build(input(%{skills_index: nil}))

    assert length(no_skills.system) == 1
    assert hd(no_skills.system)["cache_control"] == %{"type" => "ephemeral"}
    assert Enum.count(no_skills.system, &Map.has_key?(&1, "cache_control")) == 1
  end

  test "B2 lands exactly on prev_turn_boundary and is absent when nil" do
    messages = [user_blocks(Enum.map(1..3, &text/1)), assistant("done"), user("current")]

    assert {:ok, with_b2} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 3}))
    assert [{block, 3}] = message_breakpoints(with_b2.messages)
    assert block["text"] == "block 3"
    assert with_b2.contract["breakpoints"] == ["B1", "B2"]

    assert {:ok, without_b2} = Prompt.build(input(%{messages: messages, prev_turn_boundary: nil}))
    assert message_breakpoints(without_b2.messages) == []
    assert without_b2.contract["breakpoints"] == ["B1"]
  end

  test "B3 triggers above 15 appended blocks and not at 15 or fewer" do
    fifteen_history = [user_blocks(Enum.map(1..15, &text/1)), user("current")]
    sixteen_history = [user_blocks(Enum.map(1..16, &text/1)), user("current")]

    assert {:ok, no_b3} = Prompt.build(input(%{messages: fifteen_history}))
    refute "B3" in no_b3.contract["breakpoints"]
    assert message_breakpoints(no_b3.messages) == []

    assert {:ok, with_b3} = Prompt.build(input(%{messages: sixteen_history}))
    assert "B3" in with_b3.contract["breakpoints"]
    assert [{block, 16}] = message_breakpoints(with_b3.messages)
    assert block["text"] == "block 16"
  end

  test "B2 is omitted when prev_turn_boundary reaches into the latest user message" do
    messages = [
      assistant("old"),
      user_blocks([text(1), text(2)]),
      user_blocks([text(3), text(4)])
    ]

    assert {:ok, result} =
             Prompt.build(input(%{messages: messages, prev_turn_boundary: 4}))

    assert message_breakpoints(result.messages) == []
    assert result.contract["breakpoints"] == ["B1"]
  end

  test "B2 walks back when boundary lands on a thinking block" do
    messages = [user_blocks([text(1), text(2), thinking(3)]), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 3}))

    assert [{block, 2}] = message_breakpoints(result.messages)
    assert block["text"] == "block 2"
    assert result.contract["breakpoints"] == ["B1", "B2"]
  end

  test "B2 walks back when boundary lands on an empty text block" do
    messages = [user_blocks([text(1), empty_text(), text(3)]), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 2}))

    assert [{block, 1}] = message_breakpoints(result.messages)
    assert block["text"] == "block 1"
    assert result.contract["breakpoints"] == ["B1", "B2"]
  end

  test "B2 is omitted when no cacheable block exists at or below the boundary" do
    messages = [user_blocks([thinking(1), empty_text(), redacted(3)]), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 3}))

    assert message_breakpoints(result.messages) == []
    assert result.contract["breakpoints"] == ["B1"]
  end

  test "B3 walks back when its target lands on a thinking block" do
    blocks = Enum.map(1..15, &text/1) ++ [thinking(16)]
    messages = [user_blocks(blocks), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages}))

    assert [{block, 15}] = message_breakpoints(result.messages)
    assert block["text"] == "block 15"
    assert result.contract["breakpoints"] == ["B1", "B3"]
  end

  test "B2 and B3 collision after walk-back keeps only B2" do
    blocks = [text(1)] ++ Enum.map(2..20, &thinking/1)
    messages = [user_blocks(blocks), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 4}))

    assert [{block, 1}] = message_breakpoints(result.messages)
    assert block["text"] == "block 1"
    assert result.contract["breakpoints"] == ["B1", "B2"]
    assert all_breakpoint_count(result) == 2
  end

  test "B3 uses the last content block before latest user after B2" do
    messages = [user_blocks(Enum.map(1..20, &text/1)), user("current")]

    assert {:ok, result} = Prompt.build(input(%{messages: messages, prev_turn_boundary: 4}))

    assert [{b2, 4}, {b3, 20}] = message_breakpoints(result.messages)
    assert b2["text"] == "block 4"
    assert b3["text"] == "block 20"
    assert result.contract["breakpoints"] == ["B1", "B2", "B3"]
  end

  test "never emits more than three breakpoints" do
    cases = [
      input(),
      input(%{skills_index: nil}),
      input(%{messages: [user_blocks(Enum.map(1..40, &text/1)), user("current")]}),
      input(%{
        messages: [user_blocks(Enum.map(1..40, &text/1)), user("current")],
        prev_turn_boundary: 2,
        late_context: "Developer context: workspace"
      })
    ]

    for args <- cases do
      assert {:ok, result} = Prompt.build(args)
      assert all_breakpoint_count(result) <= 3
      assert length(result.contract["breakpoints"]) <= 3
    end
  end

  test "late context is leading latest user block and nothing on or after it is cached" do
    messages = [user_blocks(Enum.map(1..16, &text/1)), user("current")]

    assert {:ok, result} =
             Prompt.build(input(%{messages: messages, late_context: "Developer context: root"}))

    latest_user = List.last(result.messages)
    [late_block | rest] = latest_user["content"]

    assert late_block["type"] == "text"
    assert late_block["text"] =~ "<<<PIXIR_PA1_LATE_CONTEXT:AUTHORITY>>>"
    assert late_block["text"] =~ "Developer context: root"
    assert late_block["text"] =~ "<<<END_PIXIR_PA1_LATE_CONTEXT>>>"
    refute Map.has_key?(late_block, "cache_control")
    assert Enum.all?(rest, &(not Map.has_key?(&1, "cache_control")))
  end

  test "contract includes pa1 label and layer0_hash" do
    assert {:ok, result} = Prompt.build(input())

    assert result.contract["prompt_contract_version"] == "pa1"
    assert is_binary(result.contract["layer0_hash"])
    assert byte_size(result.contract["layer0_hash"]) == 16
  end

  test "invalid input returns structured errors" do
    assert {:error, %{ok: false, error: %{kind: :invalid_args, details: %{field: :messages}}}} =
             Prompt.build(input(%{messages: "not messages"}))

    assert {:error, %{ok: false, error: %{kind: :invalid_args, details: %{field: :mode}}}} =
             Prompt.build(input(%{mode: :review}))
  end
end
