defmodule PixirMonitor.TestRunIsolationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins the #555 per-run tmp/profile isolation contract.

  The planted-foreign-dir proof shows that a concurrent suite's
  `pixir-monitor-browser-*` name (the old host-global glob) cannot enter this
  suite's snapshot. The grep-tier pin keeps the old unscoped literals from
  returning.
  """

  @test_root Path.expand(".", __DIR__)

  test "browser profile snapshot ignores a foreign-named dir the old glob would have caught" do
    foreign =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-browser-foreign-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(foreign)
    on_exit(fn -> File.rm_rf(foreign) end)

    # Concatenation (not a single "prefix*" literal) so this proof can name the
    # old host-global glob without tripping the grep-tier pin below.
    old_glob = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-browser-" <> "*"))
    scoped = Path.wildcard(PixirMonitor.TestRun.profile_glob("pixir-monitor-browser"))

    assert foreign in old_glob
    refute foreign in scoped
  end

  test "accessibility profile snapshot ignores a foreign-named dir the old glob would have caught" do
    foreign =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-a11y-foreign-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(foreign)
    on_exit(fn -> File.rm_rf(foreign) end)

    old_glob = Path.wildcard(Path.join(System.tmp_dir!(), "pixir-monitor-a11y-" <> "*"))
    scoped = Path.wildcard(PixirMonitor.TestRun.profile_glob("pixir-monitor-a11y"))

    assert foreign in old_glob
    refute foreign in scoped
  end

  test "tmp roots and profile prefixes carry the per-run key" do
    run = PixirMonitor.TestRun.id()
    assert run =~ ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/

    root = PixirMonitor.TestRun.tmp("pixir-monitor-isolation")
    assert Path.basename(root) =~ ~r/\Apixir-monitor-isolation-#{Regex.escape(run)}-\d+\z/

    assert PixirMonitor.TestRun.profile_prefix("pixir-monitor-browser") ==
             "pixir-monitor-browser-#{run}-"

    assert PixirMonitor.TestRun.profile_glob("pixir-monitor-browser") ==
             Path.join(System.tmp_dir!(), "pixir-monitor-browser-#{run}-*")
  end

  test "no test hardcodes a shared tmp profile prefix without the per-run key" do
    files =
      Path.wildcard(Path.join(@test_root, "**/*.{ex,exs,mjs}"))
      |> Enum.reject(&String.ends_with?(&1, "/test_run_isolation_test.exs"))

    assert files != []

    offenders =
      Enum.flat_map(files, fn path ->
        source = File.read!(path)
        relative = Path.relative_to(path, Path.expand("..", @test_root))

        Enum.flat_map(forbidden_literals(), fn literal ->
          if String.contains?(source, literal) do
            ["#{relative} contains #{inspect(literal)}"]
          else
            []
          end
        end)
      end)

    assert offenders == [],
           "unscoped host-global tmp prefixes must go through PixirMonitor.TestRun " <>
             "or PIXIR_MONITOR_TEST_RUN; found:\n" <> Enum.join(offenders, "\n")
  end

  defp forbidden_literals do
    [
      ~s|Path.join(System.tmp_dir!(), "pixir-monitor-browser-*")|,
      ~s|Path.join(System.tmp_dir!(), "pixir-monitor-a11y-*")|,
      ~s|join(tmpdir(), "pixir-monitor-browser-")|,
      ~s|join(tmpdir(), "pixir-monitor-a11y-")|
    ]
  end
end
