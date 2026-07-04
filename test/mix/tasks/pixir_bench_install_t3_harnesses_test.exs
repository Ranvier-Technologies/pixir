defmodule Mix.Tasks.Pixir.Bench.InstallT3HarnessesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Bench.InstallT3Harnesses, as: InstallTask

  setup do
    t3_dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-install-t3-harnesses-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(t3_dir)
    on_exit(fn -> File.rm_rf!(t3_dir) end)

    %{t3_dir: t3_dir}
  end

  test "--json --help is machine-readable" do
    payload =
      capture_io(fn ->
        assert catch_exit(InstallTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.bench.install_t3_harnesses"
    assert length(payload["templates"]) == 2
  end

  test "--dry-run --json reports writes without installing", %{t3_dir: t3_dir} do
    payload =
      capture_io(fn ->
        InstallTask.run([
          "--dry-run",
          "--json",
          "--t3-code-path",
          t3_dir
        ])
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert length(payload["actions"]) == 2
    assert length(payload["would_write"]) == 2
    refute File.exists?(Path.join(t3_dir, "scripts/pixir-subagents-benchmark.ts"))
    refute File.exists?(Path.join(t3_dir, "scripts/codex-subagents-observability-probe.ts"))
  end

  test "installs templates and then reports them up to date", %{t3_dir: t3_dir} do
    install_payload =
      capture_io(fn ->
        InstallTask.run([
          "--json",
          "--t3-code-path",
          t3_dir
        ])
      end)
      |> Jason.decode!()

    assert install_payload["ok"] == true
    assert install_payload["mode"] == "install"
    assert Enum.map(install_payload["actions"], & &1["action"]) == ["install", "install"]

    pixir_target = Path.join(t3_dir, "scripts/pixir-subagents-benchmark.ts")
    codex_target = Path.join(t3_dir, "scripts/codex-subagents-observability-probe.ts")
    assert File.exists?(pixir_target)
    assert File.exists?(codex_target)

    dry_run_payload =
      capture_io(fn ->
        InstallTask.run([
          "--dry-run",
          "--json",
          "--t3-code-path",
          t3_dir
        ])
      end)
      |> Jason.decode!()

    assert Enum.map(dry_run_payload["actions"], & &1["action"]) == [
             "up_to_date",
             "up_to_date"
           ]

    assert dry_run_payload["would_write"] == []
  end

  test "conflicting local harness requires force", %{t3_dir: t3_dir} do
    target = Path.join(t3_dir, "scripts/pixir-subagents-benchmark.ts")
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, "local edit\n")

    payload =
      capture_io(fn ->
        assert catch_exit(
                 InstallTask.run([
                   "--json",
                   "--t3-code-path",
                   t3_dir
                 ])
               ) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "target_exists"
    assert length(payload["error"]["details"]["conflicts"]) == 1
  end
end
