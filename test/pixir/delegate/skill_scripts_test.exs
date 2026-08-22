defmodule Pixir.Delegate.SkillScriptsTest do
  use ExUnit.Case, async: true

  @fanout_script Path.expand("../../../.agents/skills/pixir-delegate/scripts/fanout.sh", __DIR__)

  # unique_integer suffixes cannot form the token "child-0" when a prefix
  # ends in "child". Hex suffixes can: fanout.sh always prints
  # `driving: $PIXIR_BIN`, and `...-child-0<hex>` false-positives the
  # fail-closed `refute output =~ "child-0"` contract (CI seed 287288 on
  # main @ 80f4f9f, run 32082472367).
  defp tmp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp refute_leaked_child_session_id(output, root) do
    refute String.contains?(root, "child-0"),
           "fixture path #{root} contains child-0; fanout driving line would false-positive"

    refute output =~ "child-0"
  end

  defp completed_child do
    %{
      "status" => "completed",
      "child_session_id" => "child-0",
      "child_log_path" => ".pixir/sessions/child-0.ndjson",
      "reason_code" => "completed",
      "retry_attempts" => 0
    }
  end

  defp completed_envelope do
    %{
      "ok" => true,
      "status" => "completed",
      "work_complete" => true,
      "children" => [completed_child()]
    }
  end

  defp partial_envelope do
    %{
      "ok" => false,
      "status" => "partial",
      "work_complete" => false,
      "children" => [
        %{
          "status" => "timed_out",
          "child_session_id" => "child-0",
          "child_log_path" => ".pixir/sessions/child-0.ndjson",
          "reason_code" => "child_timed_out",
          "retry_attempts" => 0,
          "resume_command" => "pixir resume child-0 \"continue safely\"",
          "diagnose_command" => "pixir diagnose session child-0 --json"
        }
      ]
    }
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
      elif [[ -n "${PIXIR_FAKE_REAL_SIGNAL:-}" ]]; then
        kill "-${PIXIR_FAKE_REAL_SIGNAL}" "$$"
        sleep 5
      else
        printf '%s\n' "$PIXIR_FAKE_REAL_JSON"
        exit "${PIXIR_FAKE_REAL_EXIT:-0}"
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

    real_json =
      cond do
        Keyword.get(opts, :real_reject?, false) -> rejection_json
        Keyword.has_key?(opts, :real_json) -> Keyword.fetch!(opts, :real_json)
        true -> Jason.encode!(completed_envelope())
      end

    real_exit =
      if Keyword.get(opts, :real_reject?, false),
        do: 2,
        else: Keyword.get(opts, :real_exit, 0)

    env = [
      {"PIXIR_BIN", fake_pixir},
      {"PIXIR_TIMEOUT_MS", Keyword.fetch!(opts, :timeout_ms)},
      {"PIXIR_SKIP_REHEARSAL",
       if(Keyword.get(opts, :skip_rehearsal?, false), do: "1", else: "0")},
      {"PIXIR_FAKE_LOG", log_path},
      {"PIXIR_FAKE_WOULD_REJECT", to_string(Keyword.get(opts, :would_reject?, false))},
      {"PIXIR_FAKE_REAL_JSON", real_json},
      {"PIXIR_FAKE_REAL_EXIT", to_string(real_exit)},
      {"PIXIR_FAKE_REAL_SIGNAL", Keyword.get(opts, :real_signal, "")}
    ]

    tasks = Keyword.get(opts, :tasks, ["inspect one bounded task"])

    {output, exit_code} =
      System.cmd("bash", [@fanout_script, out_dir | tasks],
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

  test "exit 0 plus a consistent complete envelope is the only success verdict" do
    root = tmp_dir!("pixir-fanout-complete")

    assert %{exit_code: 0, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: Jason.encode!(completed_envelope()),
               real_exit: 0
             )

    assert output =~ "completed"
    assert output =~ "child-0"
  end

  test "exit 6 plus a valid partial envelope normalizes to bounded wrapper recovery exit 3" do
    root = tmp_dir!("pixir-fanout-partial")

    assert %{exit_code: 3, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: Jason.encode!(partial_envelope()),
               real_exit: 6
             )

    assert output =~ "partial"
    assert output =~ "child-0"
    assert output =~ "resume"
    assert byte_size(output) < 4_096
  end

  test "partial envelope requires the exact Pixir terminal-incomplete exit 6" do
    for process_exit <- [0, 1, 2, 7] do
      root = tmp_dir!("pixir-fanout-partial-exit-#{process_exit}")

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(partial_envelope()),
                 real_exit: process_exit
               )

      assert output =~ "Pixir exit #{process_exit} contradicts a partial envelope"
      refute_leaked_child_session_id(output, root)
      assert byte_size(output) < 2_048
    end
  end

  test "a nonzero Pixir exit cannot be forged into complete wrapper success" do
    root = tmp_dir!("pixir-fanout-forged-complete")

    assert %{exit_code: 2, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: Jason.encode!(completed_envelope()),
               real_exit: 6
             )

    assert output =~ "exit 6"
  end

  test "rejected and error envelopes fail closed before child traversal" do
    for status <- ["rejected", "error"] do
      root = tmp_dir!("pixir-fanout-#{status}")

      envelope = %{
        "ok" => false,
        "status" => status,
        "work_complete" => false,
        "children" => []
      }

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(envelope),
                 real_exit: 2
               )

      assert output =~ status
      refute output =~ "Cannot iterate"
    end
  end

  test "malformed JSON fails closed" do
    root = tmp_dir!("pixir-fanout-malformed-json")

    assert %{exit_code: 2, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: "this is not JSON",
               real_exit: 0
             )

    assert output =~ "did not return one valid JSON object"
  end

  test "missing or malformed children fail closed before traversal without leaking payloads" do
    unsafe_marker = "UNSAFE-ENVELOPE-PAYLOAD-MUST-NOT-PRINT"

    malformed_envelopes = [
      Map.delete(completed_envelope(), "children"),
      Map.put(completed_envelope(), "children", %{"not" => "an array"}),
      Map.put(completed_envelope(), "children", [unsafe_marker]),
      Map.put(completed_envelope(), "children", [
        completed_child()
        |> Map.put("child_session_id", unsafe_marker <> "\ncontrol")
        |> Map.put("retry_attempts", "many")
      ])
    ]

    for {envelope, index} <- Enum.with_index(malformed_envelopes) do
      root = tmp_dir!("pixir-fanout-malformed-children-#{index}")

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(envelope),
                 real_exit: 0
               )

      assert output =~ "invalid envelope"
      refute output =~ unsafe_marker
      refute output =~ "Cannot iterate"
    end
  end

  test "child identifiers reject hostile trailing newlines with absolute regex anchors" do
    hostile_fields = [
      {"child_session_id", "child-0\n"},
      {"reason_code", "completed\n"}
    ]

    for {field, hostile_value} <- hostile_fields do
      root = tmp_dir!("pixir-fanout-hostile-#{field}")
      hostile_child = Map.put(completed_child(), field, hostile_value)
      envelope = Map.put(completed_envelope(), "children", [hostile_child])

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(envelope),
                 real_exit: 0
               )

      assert output =~ "invalid envelope child shape"
      refute output =~ hostile_value
      assert byte_size(output) < 2_048
    end
  end

  test "complete envelope with a failed child fails closed as contradictory evidence" do
    root = tmp_dir!("pixir-fanout-complete-failed-child")

    failed_child =
      completed_child()
      |> Map.put("status", "failed")
      |> Map.put("reason_code", "child_failed")

    envelope = Map.put(completed_envelope(), "children", [failed_child])

    assert %{exit_code: 2, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: Jason.encode!(envelope),
               real_exit: 0
             )

    assert output =~ "complete envelope contains a non-completed child"
    refute output =~ "child_failed"
    assert byte_size(output) < 2_048
  end

  test "partial envelope with every child completed fails closed as contradictory evidence" do
    root = tmp_dir!("pixir-fanout-partial-all-completed")

    envelope =
      partial_envelope()
      |> Map.put("children", [completed_child()])

    assert %{exit_code: 2, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_json: Jason.encode!(envelope),
               real_exit: 6
             )

    assert output =~ "partial envelope has no non-completed child"
    refute_leaked_child_session_id(output, root)
    assert byte_size(output) < 2_048
  end

  test "fail-closed child-0 refute rejects fixture paths that contain child-0" do
    colliding = "/tmp/pixir-fanout-partial-completed-child-0ed9e388ec8f"

    assert_raise ExUnit.AssertionError, fn ->
      refute_leaked_child_session_id(
        "error: partial envelope has no non-completed child; refusing contradictory fan-out evidence\n",
        colliding
      )
    end
  end

  test "genuine partial spawn with fewer completed children preserves wrapper partial exit 3" do
    root = tmp_dir!("pixir-fanout-genuine-partial-spawn")

    envelope =
      partial_envelope()
      |> Map.put("children", [completed_child()])
      |> Map.put("spawn_failure", %{"kind" => "spawn_failed"})
      |> Map.put("beam_coordination", %{
        "planned_child_count" => 2,
        "spawned_child_count" => 1
      })

    assert %{exit_code: 3, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               tasks: ["first bounded task", "second bounded task"],
               real_json: Jason.encode!(envelope),
               real_exit: 6
             )

    assert output =~ "partial"
    assert output =~ "child-0"
    assert byte_size(output) < 4_096
  end

  test "malformed or forged partial-spawn count mismatches fail closed" do
    base =
      partial_envelope()
      |> Map.put("children", [completed_child()])
      |> Map.put("spawn_failure", %{"kind" => "spawn_failed"})
      |> Map.put("beam_coordination", %{
        "planned_child_count" => 2,
        "spawned_child_count" => 1
      })

    malformed = [
      Map.delete(base, "spawn_failure"),
      Map.put(base, "spawn_failure", "forged"),
      Map.delete(base, "beam_coordination"),
      Map.put(base, "beam_coordination", "forged"),
      Map.put(base, "beam_coordination", %{
        "planned_child_count" => "2",
        "spawned_child_count" => 1
      }),
      Map.put(base, "beam_coordination", %{
        "planned_child_count" => 3,
        "spawned_child_count" => 1
      }),
      Map.put(base, "beam_coordination", %{
        "planned_child_count" => 2,
        "spawned_child_count" => -1
      }),
      Map.put(base, "beam_coordination", %{
        "planned_child_count" => 2,
        "spawned_child_count" => 2
      }),
      Map.put(base, "ok", true),
      base |> Map.put("status", "completed") |> Map.put("work_complete", true)
    ]

    for {envelope, index} <- Enum.with_index(malformed) do
      root = tmp_dir!("pixir-fanout-forged-partial-spawn-#{index}")

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 tasks: ["first bounded task", "second bounded task"],
                 real_json: Jason.encode!(envelope),
                 real_exit: 6
               )

      assert output =~ "envelope child count does not match spec task count"
      refute_leaked_child_session_id(output, root)
      assert byte_size(output) < 2_048
    end
  end

  test "child count must match the generated spec task count" do
    mismatched_children = [
      [],
      [completed_child(), Map.put(completed_child(), "child_session_id", "child-1")]
    ]

    for {children, index} <- Enum.with_index(mismatched_children) do
      root = tmp_dir!("pixir-fanout-child-count-mismatch-#{index}")
      envelope = Map.put(completed_envelope(), "children", children)

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(envelope),
                 real_exit: 0
               )

      assert output =~ "envelope child count does not match spec task count"
      refute_leaked_child_session_id(output, root)
      assert byte_size(output) < 2_048
    end
  end

  test "signal termination fails closed even when no envelope is available" do
    root = tmp_dir!("pixir-fanout-signal")

    assert %{exit_code: 2, output: output} =
             run_fanout(root,
               timeout_ms: "100000",
               skip_rehearsal?: true,
               real_signal: "TERM"
             )

    assert output =~ "terminated by signal"
  end

  test "contradictory ok status and work_complete triples fail closed" do
    contradictory = [
      %{"ok" => false, "status" => "completed", "work_complete" => true},
      %{"ok" => true, "status" => "completed", "work_complete" => false},
      %{"ok" => true, "status" => "partial", "work_complete" => false},
      %{"ok" => false, "status" => "partial", "work_complete" => true}
    ]

    for {fields, index} <- Enum.with_index(contradictory) do
      root = tmp_dir!("pixir-fanout-contradictory-#{index}")
      envelope = Map.put(fields, "children", [completed_child()])

      assert %{exit_code: 2, output: output} =
               run_fanout(root,
                 timeout_ms: "100000",
                 skip_rehearsal?: true,
                 real_json: Jason.encode!(envelope),
                 real_exit: 0
               )

      assert output =~ "contradictory"
    end
  end
end
