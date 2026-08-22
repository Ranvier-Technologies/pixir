defmodule Pixir.OperatorStateIsolationTest do
  use ExUnit.Case, async: false

  alias Pixir.Test.OperatorState

  @moduledoc """
  Pins the #563 operator-state isolation contract.

  Two leak paths, one class: the suite must not read undeclared discovery roots.

  1. `PIXIR_HOME` defaults to `~/.pixir` and leaks model / `compaction.native`
     into CompactionTest and ProviderTest fold/overlay assertions.
  2. Skills `user_home` defaults to `$HOME/.agents/skills` (and
     `$PIXIR_HOME/skills`) and leaks extra names into ACP exact-index pins.

  The planted-operator proof writes a real-looking config and extra Skill names,
  then asserts isolation hides them. Deleting `isolate!/1`'s redirect makes the
  planted names and overlay-off config visible again — that is the gate.
  """

  @pinned_files [
    "test/pixir/compaction_test.exs",
    "test/pixir/provider_test.exs",
    "test/pixir/acp/server_test.exs"
  ]

  test "planted operator PIXIR_HOME and user Skills leak without isolation" do
    roots = OperatorState.expose_planted!()
    workspace = declared_workspace(["alpha"])
    loaded = Pixir.Config.load()

    assert loaded["present"]
    assert loaded["path"] == Path.expand(Path.join(roots.pixir_home, "config.json"))
    assert get_in(loaded, ["effective", "compaction", "native"]) == false

    planted = roots.pixir_home |> Path.join("config.json") |> File.read!() |> Jason.decode!()
    assert planted["model"] == OperatorState.operator_model()

    {:ok, %{skills: skills}} = Pixir.Skills.discover(workspace)
    names = Enum.map(skills, & &1.name)

    assert OperatorState.operator_skill() in names
    assert OperatorState.operator_global_skill() in names
    assert "alpha" in names
  end

  test "isolation hides planted operator PIXIR_HOME config and extra Skills" do
    roots = OperatorState.isolate_discovery_roots!()
    workspace = declared_workspace(["alpha"])
    loaded = Pixir.Config.load()

    assert loaded["present"] == false
    assert loaded["path"] == Path.expand(Path.join(roots.pixir_home, "config.json"))
    assert get_in(loaded, ["effective", "compaction", "native"]) == nil
    refute File.exists?(Path.join(roots.pixir_home, "config.json"))
    refute File.dir?(Path.join([roots.user_home, ".agents", "skills"]))

    {:ok, %{skills: skills}} = Pixir.Skills.discover(workspace)
    names = Enum.map(skills, & &1.name)

    assert names == ["alpha"]
    refute OperatorState.operator_skill() in names
    refute OperatorState.operator_global_skill() in names
  end

  test "the six leaky files call the shared isolate helper" do
    offenders =
      Enum.flat_map(@pinned_files, fn relative ->
        source = File.read!(Path.expand(relative))

        cond do
          relative == "test/pixir/acp/server_test.exs" and
              not String.contains?(source, "OperatorState.isolate_discovery_roots!") ->
            ["#{relative} must call OperatorState.isolate_discovery_roots!"]

          relative != "test/pixir/acp/server_test.exs" and
              not String.contains?(source, "OperatorState.isolate_pixir_home!") ->
            ["#{relative} must call OperatorState.isolate_pixir_home!"]

          true ->
            []
        end
      end)

    assert offenders == [],
           "deleting the #563 isolation from a leaky file reopens operator-state bleed:\n" <>
             Enum.join(offenders, "\n")
  end

  defp declared_workspace(names) do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "pixir-operator-declared-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    Enum.each(names, fn name ->
      dir = Path.join([workspace, ".agents", "skills", name])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "SKILL.md"), """
      ---
      name: #{name}
      description: Declared #{name} fixture
      ---

      # Declared #{name} fixture
      """)
    end)

    workspace
  end
end
