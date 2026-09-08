defmodule PixirMonitor.Projection.BoundedLogTest do
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.BoundedLog

  test "read failures retain the existing reason and corrupt diagnostics retain the Log path" do
    for reason <- [:eacces, "log_changed_during_read"] do
      assert {:error, %{kind: "run_log_failed", details: %{reason: ^reason}}} =
               BoundedLog.error(%{error: %{kind: :log_read_failed, details: %{reason: reason}}}, "run-1")
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        BoundedLog.error(%{error: %{kind: :corrupt_log_line, details: %{path: "/workspace/.pixir/sessions/run-1.ndjson"}}}, "run-1")
      end)

    assert log =~ "path=/workspace/.pixir/sessions/run-1.ndjson"
  end

  # Reader ownership coverage moved to test/pixir/log_bounded_test.exs in core.
  # Monitor owns only the Presenter-facing limitations and error adaptation.
  test "prefix-tail limitations preserve the existing unknown-count vocabulary" do
    selection = %{"partial" => true, "bytes_omitted" => 300, "events_retained" => 2, "bytes_read" => 1024}
    assert {:ok, [note | limits]} = BoundedLog.limitations(selection)
    assert note == "parent_log_prefix_tail:bytes_omitted=300;events_omitted=unknown;events_retained=2;bytes_read=1024"
    assert limits == ["partial_counts_lower_bounds", "parent_log_missing_middle", "omitted_event_count_unverifiable"]
  end

  test "unfinished append and complete selection formatting remain distinct" do
    assert {:ok, ["parent_log_incomplete_trailing_append"]} = BoundedLog.limitations(%{"partial" => false, "incomplete_trailing_bytes" => 42})
    assert {:ok, []} = BoundedLog.limitations(%{"partial" => false, "incomplete_trailing_bytes" => 0})
  end

  test "core failures map to the existing Monitor error fields" do
    for {core_kind, monitor_kind} <- [
          log_not_found: "run_not_found",
          log_read_limit: "run_log_limit",
          log_event_limit: "run_event_limit",
          invalid_args: "invalid_run_id",
          corrupt_log_line: "run_log_failed",
          invalid_log_selection: "run_log_failed",
          log_read_failed: "run_log_failed"
        ] do
      error = %{error: %{kind: core_kind, details: %{path: "/private/workspace/log", reason: :eacces, bytes: 9000}}}
      assert {:error, %{kind: ^monitor_kind, details: details} = adapted} = BoundedLog.error(error, "run-1")
      assert details.run_id == "run-1"
      assert details.bytes == 9000
      refute inspect(adapted) =~ "/private"
      refute inspect(adapted) =~ "private record contents"
    end
  end

  test "unsafe path adaptation distinguishes state ancestors from final Logs" do
    for {index, expected} <- [{0, "state_tree_symlink_rejected"}, {1, "state_tree_symlink_rejected"}, {2, "symlink_rejected"}] do
      core = %{error: %{kind: :unsafe_state_path, details: %{"reason" => "symlink_component", "component_index" => index}}}
      assert {:error, %{kind: ^expected, details: details}} = BoundedLog.error(core, "run-1")
      if index == 0, do: assert(details.component == ".pixir")
      if index == 1, do: assert(details.component == "sessions")
    end

    core = %{error: %{kind: :unsafe_state_path, details: %{"reason" => "unexpected_file_type", "component_index" => 2}}}
    assert {:error, %{kind: "run_log_invalid"}} = BoundedLog.error(core, "run-1")
  end
end
