Code.require_file("support/semantic_zoom_fixture.ex", __DIR__)
Code.require_file("support/fixture_workspace.ex", __DIR__)

defmodule PixirMonitor.FixtureMaterializationTest do
  use ExUnit.Case, async: false

  alias PixirMonitor.FixtureWorkspace
  alias PixirMonitor.Projection.{Builder, Source}
  alias PixirMonitor.SemanticZoomFixture

  @parent_log_unit_fields ~w(
    logical_id unit_kind materialization label agent execution_kind workspace_mode posture
    depends_on execution gate liveness advisory artifacts mutation safe_actions evidence_refs
  )
  @observed_completeness_limitations ~w(child_log_missing usage_incomplete_missing_child_log)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-monitor-fixture-workspace-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "materialized 100-unit and 500-unit fixtures match direct graph projections", %{
    root: root
  } do
    for {name, input} <- fixture_inputs() do
      workspace = Path.join(root, name)
      run_id = FixtureWorkspace.materialize!(input, workspace)

      assert {:ok, direct} = Builder.build(input)
      assert {:ok, served} = Source.fetch_run(run_id, workspace: workspace)
      assert served["run"]["strategy"] == "workflow"
      assert served["graph"] == direct["graph"]

      # The fixture declares child-log completeness, while Source derives completeness
      # from the child Logs actually present on disk. Parent-log truth stays equal, but
      # the served projection must honestly report that this parent-only workspace has
      # no child Logs rather than inheriting the fixture's declaration.
      direct_units = Map.new(direct["units"], &{&1["logical_id"], &1})

      for served_unit <- served["units"] do
        direct_unit = Map.fetch!(direct_units, served_unit["logical_id"])

        assert Map.take(served_unit, @parent_log_unit_fields) ==
                 Map.take(direct_unit, @parent_log_unit_fields)

        assert served_unit["limitations"] == @observed_completeness_limitations
        assert direct_unit["limitations"] == []
        assert served_unit["attention"]["required"]

        assert served_unit["attention"]["reasons"] ==
                 direct_unit["attention"]["reasons"] ++ ["child_log_missing"]

        refute "child_log_missing" in direct_unit["attention"]["reasons"]

        assert Map.take(direct_unit["usage"], ~w(source complete limitations)) == %{
                 "source" => "none",
                 "complete" => true,
                 "limitations" => []
               }

        assert served_unit["usage"] ==
                 Map.merge(direct_unit["usage"], %{
                   "source" => "incomplete",
                   "complete" => false,
                   "limitations" => ["usage_incomplete_missing_child_log"]
                 })
      end

      assert served["limitations"] ==
               direct["limitations"] ++ @observed_completeness_limitations
    end
  end

  test "materialization is byte-identical and writes only the parent session log", %{
    root: root
  } do
    for {name, input} <- fixture_inputs() do
      first = Path.join(root, "#{name}-first")
      second = Path.join(root, "#{name}-second")
      first_run_id = FixtureWorkspace.materialize!(input, first)
      second_run_id = FixtureWorkspace.materialize!(input, second)

      assert first_run_id == second_run_id

      first_sessions = Path.join([first, ".pixir", "sessions"])
      second_sessions = Path.join([second, ".pixir", "sessions"])
      filename = "#{first_run_id}.ndjson"

      assert {:ok, [^filename]} = File.ls(first_sessions)
      assert {:ok, [^filename]} = File.ls(second_sessions)
      assert File.read!(Path.join(first_sessions, filename)) == File.read!(Path.join(second_sessions, filename))
    end
  end

  test "refuses to materialize a Log for a session id that escapes the sessions directory", %{
    root: root
  } do
    workspace = Path.join(root, "traversal")

    for unsafe <- [
          "../escape",
          "nested/child",
          "..",
          ".",
          "",
          "a/../../b",
          "/etc/passwd",
          "foo\0bar",
          "foo∕bar",
          ".hidden",
          ".. "
        ] do
      input =
        put_in(
          SemanticZoomFixture.input(),
          ["inputs", "terminal_envelope", "parent_session_id"],
          unsafe
        )

      assert_raise ArgumentError, fn -> FixtureWorkspace.materialize!(input, workspace) end
    end

    # Nothing escaped the sessions directory: no stray Log above it, no nested dir.
    refute File.exists?(Path.join(root, "escape.ndjson"))
    refute File.dir?(Path.join(workspace, "nested"))
  end

  defp fixture_inputs do
    [{"100", SemanticZoomFixture.input()}, {"500", SemanticZoomFixture.input_500()}]
  end
end
