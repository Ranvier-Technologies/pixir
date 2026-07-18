Code.require_file("../test/support/semantic_zoom_fixture.ex", __DIR__)
Code.require_file("../test/support/fixture_workspace.ex", __DIR__)

defmodule PixirMonitor.EmitFixtureWorkspace do
  @moduledoc false

  alias PixirMonitor.FixtureWorkspace
  alias PixirMonitor.SemanticZoomFixture

  @spec run([String.t()]) :: :ok
  def run(argv) do
    case parse(argv) do
      {:ok, fixture, output_directory} ->
        input = fixture_input(fixture)
        run_id = FixtureWorkspace.materialize!(input, output_directory)

        print(%{
          "fixture" => fixture,
          "out" => output_directory,
          "run_id" => run_id,
          "events" => length(get_in(input, ["inputs", "parent_log"]))
        })

      {:error, message} ->
        print_error(message)
        System.halt(1)
    end
  rescue
    exception ->
      print_error(Exception.message(exception), "fixture_materialization_failed")
      System.halt(1)
  end

  defp parse(argv) do
    {options, positional, invalid} =
      argv
      |> drop_separator()
      |> OptionParser.parse(strict: [fixture: :string, out: :string])

    fixture = Keyword.get(options, :fixture)
    output_directory = Keyword.get(options, :out)

    valid_options? =
      options
      |> Keyword.keys()
      |> Enum.sort() == [:fixture, :out]

    if valid_options? and positional == [] and invalid == [] and fixture in ["100", "500", "hostile"] and
         is_binary(output_directory) and output_directory != "" do
      {:ok, fixture, output_directory}
    else
      {:error,
       "expected mix run --no-start bench/emit_fixture_workspace.exs --fixture 100|500|hostile --out <dir>"}
    end
  end

  defp drop_separator(["--" | rest]), do: rest
  defp drop_separator(argv), do: argv

  defp fixture_input("100"), do: SemanticZoomFixture.input()
  defp fixture_input("500"), do: SemanticZoomFixture.input_500()
  defp fixture_input("hostile"), do: SemanticZoomFixture.hostile_input_500()

  defp print(value), do: IO.puts(Jason.encode!(value))

  defp print_error(message, kind \\ "invalid_arguments") do
    IO.puts(:stderr, Jason.encode!(%{"error" => %{"kind" => kind, "message" => message}}))
  end
end

PixirMonitor.EmitFixtureWorkspace.run(System.argv())
