defmodule Mix.Tasks.Pixir.Smoke.WorkflowsRealTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.WorkflowsReal, as: SmokeTask

  setup do
    output_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-smoke-workflows-real-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{output_dir: output_dir}
  end

  test "--json --help is machine-readable and exits before app start" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.workflows_real"
    assert payload["network"] == true
    assert "micro_parallel" in payload["scenarios"]
    assert "does_not_call_provider" in payload["dry_run_guarantees"]
  end

  test "--dry-run --json validates scenario without creating output", %{output_dir: output_dir} do
    payload =
      capture_io(fn ->
        assert catch_exit(
                 SmokeTask.run([
                   "--dry-run",
                   "--json",
                   "--scenario",
                   "dependency",
                   "--output",
                   output_dir
                 ])
               ) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["scenario"] == "dependency"
    assert payload["network"] == false
    assert payload["estimated_model_backed_subagents"] == 3
    assert Path.join(output_dir, "evidence.json") in payload["would_write"]
    refute File.exists?(output_dir)
  end

  test "invalid scenarios return structured actionable errors" do
    payload =
      capture_io(:stderr, fn ->
        assert catch_exit(SmokeTask.run(["--scenario", "big_repo", "--json"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_scenario"
    assert payload["error"]["details"]["scenario"] == "big_repo"
    assert Enum.any?(payload["next_steps"], &String.contains?(&1, "--dry-run --json"))
  end

  test "malformed command profile preflight blocks before Auth and workflow fan-out" do
    for {profile, kind} <- profile_cases() do
      with_profile(profile, fn ->
        payload =
          capture_io(:stderr, fn ->
            assert catch_exit(SmokeTask.run(["--json"])) == {:shutdown, 1}
          end)
          |> Jason.decode!()

        assert payload["ok"] == false
        assert payload["schema_version"] == 1
        assert payload["command"] == "mix pixir.smoke.workflows_real"
        assert payload["error"]["kind"] == kind
        assert payload["next_steps"] != []
      end)
    end
  end

  defp profile_cases do
    [{%{"mode" => "future"}, "invalid_config"}]
  end

  defp with_profile(profile, fun) do
    home =
      Path.join(System.tmp_dir!(), "pixir-workflow-profile-#{System.unique_integer([:positive])}")

    prior_home = System.get_env("PIXIR_HOME")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"responses_backend" => profile}))
    System.put_env("PIXIR_HOME", home)

    try do
      fun.()
    after
      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end
end
