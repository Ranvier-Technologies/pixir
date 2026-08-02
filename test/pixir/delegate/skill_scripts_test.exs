defmodule Pixir.Delegate.SkillScriptsTest do
  use ExUnit.Case, async: true

  @fanout_script Path.expand("../../../.agents/skills/pixir-delegate/scripts/fanout.sh", __DIR__)

  defp tmp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp fake_pixir!(root) do
    path = Path.join(root, "fake-pixir")

    File.write!(
      path,
      ~S"""
      #!/usr/bin/env bash
      set -euo pipefail

      if [[ "${1:-}" == "--version" ]]; then
        echo "fake"
        exit 0
      fi

      if [[ "${1:-}" != "delegate" ]]; then
        echo "unexpected invocation: $*" >&2
        exit 64
      fi

      printf '%s\n' "$*" >>"$PIXIR_FAKE_LOG"

      if [[ " $* " == *" --dry-run "* ]]; then
        printf '{"status":"planned","would_reject":%s,"beam_coordination":{"planned_child_count":1}}\n' \
          "${PIXIR_FAKE_WOULD_REJECT:-false}"
      elif [[ "${PIXIR_FAKE_REAL_REJECT:-false}" == "true" ]]; then
        printf '%s\n' "${PIXIR_FAKE_REJECTION_JSON}"
        exit 2
      else
        printf '{"status":"completed","work_complete":true,"children":[]}\n'
      fi
      """
    )

    File.chmod!(path, 0o755)
    path
  end

  defp run_fanout(root, opts) do
    out_dir = Path.join(root, "out")
    log_path = Path.join(root, "invocations.log")
    fake_pixir = fake_pixir!(root)

    rejection_json =
      Jason.encode!(%{
        "ok" => false,
        "status" => "rejected",
        "kind" => "horizon_shorter_than_critical_path",
        "message" => "1 waves x 120000ms per wave = 120000ms > 100000ms horizon",
        "details" => %{
          "suggested_timeout_ms" => 120_000,
          "next_actions" => ["increase_wait_horizon_to_suggested_timeout_ms"]
        }
      })

    env = [
      {"PIXIR_BIN", fake_pixir},
      {"PIXIR_TIMEOUT_MS", Keyword.fetch!(opts, :timeout_ms)},
      {"PIXIR_SKIP_REHEARSAL",
       if(Keyword.get(opts, :skip_rehearsal?, false), do: "1", else: "0")},
      {"PIXIR_FAKE_LOG", log_path},
      {"PIXIR_FAKE_WOULD_REJECT", to_string(Keyword.get(opts, :would_reject?, false))},
      {"PIXIR_FAKE_REAL_REJECT", to_string(Keyword.get(opts, :real_reject?, false))},
      {"PIXIR_FAKE_REJECTION_JSON", rejection_json}
    ]

    {output, exit_code} =
      System.cmd("bash", [@fanout_script, out_dir, "inspect one bounded task"],
        env: env,
        stderr_to_stdout: true
      )

    invocations =
      case File.read(log_path) do
        {:ok, contents} -> String.split(contents, "\n", trim: true)
        {:error, :enoent} -> []
      end

    %{exit_code: exit_code, output: output, out_dir: out_dir, invocations: invocations}
  end

  test "rehearsal and real delegate receive the identical configured timeout" do
    root = tmp_dir!("pixir-fanout-timeout")

    assert %{exit_code: 0, invocations: [rehearsal, real]} =
             run_fanout(root, timeout_ms: "234567")

    assert rehearsal =~ "delegate --spec"
    assert rehearsal =~ "--dry-run --json"
    assert rehearsal =~ "--timeout-ms 234567"
    assert real =~ "delegate --spec"
    refute real =~ "--dry-run"
    assert real =~ "--timeout-ms 234567"
  end

  test "a nonfatal rehearsal would_reject result exits 2 without invoking the real run" do
    root = tmp_dir!("pixir-fanout-rejection")

    assert %{exit_code: 2, invocations: [rehearsal], output: output, out_dir: out_dir} =
             run_fanout(root, timeout_ms: "90000", would_reject?: true)

    assert rehearsal =~ "--dry-run"
    assert rehearsal =~ "--timeout-ms 90000"
    assert output =~ "rehearsal"
    refute File.exists?(Path.join(out_dir, "envelope.json"))
  end

  test "skipped rehearsal preserves a structured horizon rejection without enumerating children" do
    root = tmp_dir!("pixir-fanout-attached-rejection")

    assert %{exit_code: 2, invocations: [real], output: output, out_dir: out_dir} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_reject?: true
             )

    refute real =~ "--dry-run"
    assert output =~ "horizon_shorter_than_critical_path"
    assert output =~ "increase_wait_horizon_to_suggested_timeout_ms"
    refute output =~ "Cannot iterate over null"
    refute output =~ "children[]"

    assert %{
             "status" => "rejected",
             "kind" => "horizon_shorter_than_critical_path"
           } = out_dir |> Path.join("envelope.json") |> File.read!() |> Jason.decode!()
  end
end
