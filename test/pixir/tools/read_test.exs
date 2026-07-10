defmodule Pixir.Tools.ReadPagingTest do
  use ExUnit.Case, async: false

  alias Pixir.SessionSupervisor
  alias Pixir.Tools.{Executor, Read}

  setup do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-read-paging-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)

    {:ok, session_id, session_pid} =
      SessionSupervisor.start_session(workspace: workspace, role: :build)

    on_exit(fn ->
      try do
        if Process.alive?(session_pid) do
          DynamicSupervisor.terminate_child(SessionSupervisor, session_pid)
        end
      catch
        :exit, _reason -> :ok
      end

      File.rm_rf!(workspace)
    end)

    %{
      workspace: workspace,
      context: %{session_id: session_id, workspace: workspace, call_id: "read_paging"}
    }
  end

  test "schema teaches the model line paging and continuation" do
    properties = Read.__tool__().parameters["properties"]

    assert properties["offset"]["minimum"] == 0
    assert properties["limit"]["minimum"] == 1
    assert properties["limit"]["description"] =~ "next_offset"
  end

  test "default read keeps small file output byte-identical", %{
    context: context,
    workspace: workspace
  } do
    contents = "alpha\nβeta\n"
    File.write!(Path.join(workspace, "small.txt"), contents)

    assert {:ok, result} = run(context, "small", %{"path" => "small.txt"})
    assert result == %{"output" => contents}
  end

  test "offset and limit return a line slice with continuation metadata", %{
    context: context,
    workspace: workspace
  } do
    contents = Enum.map_join(1..6, "\n", &"line #{&1}")
    File.write!(Path.join(workspace, "slice.txt"), contents)

    assert {:ok, result} =
             run(context, "slice", %{"path" => "slice.txt", "offset" => 2, "limit" => 2})

    assert result["output"] ==
             "line 2\nline 3\n" <>
               "[truncated: showing lines 2-3 of 6; continue with offset=4]"

    assert result["lines_total"] == 6
    assert result["lines_returned"] == 2
    assert result["offset_effective"] == 2
    assert result["next_offset"] == 4
  end

  test "byte truncation replaces the generic marker with line guidance", %{
    context: context,
    workspace: workspace
  } do
    contents = Enum.map_join(1..400, "\n", &"#{&1}:#{String.duplicate("x", 80)}")
    File.write!(Path.join(workspace, "large.txt"), contents)

    assert {:ok, result} = run(context, "large", %{"path" => "large.txt"})

    assert result["lines_total"] == 400
    assert result["lines_returned"] < result["lines_total"]
    assert result["offset_effective"] == 1
    assert result["next_offset"] == result["lines_returned"] + 1

    guidance =
      "[truncated: showing lines 1-#{result["lines_returned"]} of 400; " <>
        "continue with offset=#{result["next_offset"]}]"

    assert String.ends_with?(result["output"], guidance)
    refute result["output"] =~ "…[truncated"
  end

  test "following next_offset reads every line of a large file exactly once", %{
    context: context,
    workspace: workspace
  } do
    contents = Enum.map_join(1..500, "\n", &"line-#{&1}-#{String.duplicate("z", 64)}")
    File.write!(Path.join(workspace, "chain.txt"), contents)

    assert {:ok, seen_lines, reads} = read_chain(context, "chain.txt", nil, [], 1)
    assert seen_lines == Enum.to_list(1..500)
    assert reads > 1
  end

  test "invalid paging and unknown arguments fail closed through Executor", %{context: context} do
    invalid_args = [
      %{"path" => "missing.txt", "offset" => -1},
      %{"path" => "missing.txt", "offset" => 1.5},
      %{"path" => "missing.txt", "offset" => "2"},
      %{"path" => "missing.txt", "limit" => 0},
      %{"path" => "missing.txt", "limit" => -1},
      %{"path" => "missing.txt", "limit" => 1.5},
      %{"path" => "missing.txt", "page" => 2}
    ]

    invalid_args
    |> Enum.with_index(1)
    |> Enum.each(fn {args, index} ->
      assert {:error, %{error: %{kind: :invalid_args}}} =
               run(context, "invalid_#{index}", args)
    end)
  end

  test "an oversized single line advances continuation with an explicit caveat", %{
    context: context,
    workspace: workspace
  } do
    File.write!(
      Path.join(workspace, "oversized.txt"),
      String.duplicate("x", 20_000) <> "\nsecond"
    )

    assert {:ok, first} = run(context, "oversized_1", %{"path" => "oversized.txt"})

    assert first["lines_total"] == 2
    assert first["lines_returned"] == 1
    assert first["offset_effective"] == 1
    assert first["next_offset"] == 2
    assert first["continuation_caveat"] =~ "continuation advances"

    assert String.ends_with?(
             first["output"],
             "[truncated: showing lines 1-1 of 2; continue with offset=2]"
           )

    refute first["output"] =~ "…[truncated"

    assert {:ok, second} =
             run(context, "oversized_2", %{"path" => "oversized.txt", "offset" => 2})

    assert second["lines_returned"] == 1
    assert second["next_offset"] == nil
    assert second["output"] =~ "second"
    assert String.ends_with?(second["output"], "[truncated: showing lines 2-2 of 2; end of file]")
  end

  defp run(context, call_id, args) do
    Executor.run(
      %{call_id: call_id, name: "read", args: args},
      %{context | call_id: call_id}
    )
  end

  defp read_chain(context, path, offset, seen_lines, read_number) do
    args =
      if is_integer(offset), do: %{"path" => path, "offset" => offset}, else: %{"path" => path}

    with {:ok, result} <- run(context, "chain_#{read_number}", args) do
      first_line = result["offset_effective"]
      last_line = first_line + result["lines_returned"] - 1
      seen_lines = seen_lines ++ Enum.to_list(first_line..last_line)

      case result["next_offset"] do
        nil -> {:ok, seen_lines, read_number}
        next -> read_chain(context, path, next, seen_lines, read_number + 1)
      end
    end
  end
end
