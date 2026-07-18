defmodule PixirMonitor.Projection.TemporalTest do
  @moduledoc """
  Frozen temporal schema and deterministic Runs ordering (private issue #333).
  """
  use ExUnit.Case, async: true

  alias PixirMonitor.Projection.Temporal

  defp sub(ts, status), do: %{"ts" => ts, "data" => %{"subagent_id" => "s", "status" => status}}

  describe "frozen temporal schema" do
    test "pins field set, evidence bases, and completeness vocabulary" do
      workflow = %{"ts" => "2026-07-10T00:00:00Z"}
      finish = %{"ts" => "2026-07-10T00:05:00Z"}
      temporal = Temporal.row_temporal(workflow, finish, [], "2026-07-10T00:05:00Z", false)

      assert Map.keys(temporal) |> Enum.sort() == ["duration", "ended_at", "latest_at", "started_at"]

      assert temporal["started_at"] == %{
               "value" => "2026-07-10T00:00:00Z",
               "basis" => "workflow_started_event_ts",
               "completeness" => "complete"
             }

      assert temporal["ended_at"]["basis"] == "workflow_finished_event_ts"
      assert temporal["latest_at"]["basis"] == "max_parent_event_ts"

      assert temporal["duration"] == %{
               "ms" => 300_000,
               "basis" => "boundary_difference",
               "completeness" => "complete"
             }

      assert Temporal.completeness_vocabulary() == ["complete", "incomplete", "unknown", "malformed"]
    end

    test "subagent-only runs derive boundaries from lifecycle evidence, never from clocks" do
      subs = [sub("2026-07-10T00:00:01Z", "started"), sub("2026-07-10T00:00:09Z", "completed")]
      temporal = Temporal.row_temporal(nil, nil, subs, "2026-07-10T00:00:09Z", true)

      assert temporal["started_at"]["basis"] == "first_subagent_lifecycle_ts"
      assert temporal["started_at"]["value"] == "2026-07-10T00:00:01Z"
      assert temporal["ended_at"]["basis"] == "terminal_subagent_lifecycle_ts"
      assert temporal["ended_at"]["value"] == "2026-07-10T00:00:09Z"
      assert temporal["duration"]["ms"] == 8000
    end

    test "a live run never manufactures an end boundary; duration is incomplete" do
      subs = [sub("2026-07-10T00:00:01Z", "started")]
      temporal = Temporal.row_temporal(nil, nil, subs, "2026-07-10T00:00:01Z", false)

      assert temporal["ended_at"] == %{"value" => nil, "basis" => nil, "completeness" => "unknown"}
      assert temporal["duration"] == %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "incomplete"}
    end

    test "absent evidence yields unknown everywhere" do
      temporal = Temporal.row_temporal(nil, nil, [], nil, false)

      for field <- ["started_at", "ended_at", "latest_at"] do
        assert temporal[field]["completeness"] == "unknown"
        assert temporal[field]["value"] == nil
      end

      assert temporal["duration"]["completeness"] == "unknown"
    end

    test "malformed timestamps are confessed as malformed and poison the duration" do
      workflow = %{"ts" => "not-a-timestamp"}
      finish = %{"ts" => "2026-07-10T00:05:00Z"}
      temporal = Temporal.row_temporal(workflow, finish, [], "garbled", false)

      assert temporal["started_at"]["completeness"] == "malformed"
      assert temporal["started_at"]["value"] == "not-a-timestamp"
      assert temporal["latest_at"]["completeness"] == "malformed"
      assert temporal["duration"] == %{"ms" => nil, "basis" => "boundary_difference", "completeness" => "malformed"}
    end

    test "timezone offsets normalize: duration compares instants, not strings" do
      workflow = %{"ts" => "2026-07-10T02:00:00+02:00"}
      finish = %{"ts" => "2026-07-10T00:00:30Z"}
      temporal = Temporal.row_temporal(workflow, finish, [], "2026-07-10T00:00:30Z", false)

      assert temporal["duration"]["ms"] == 30_000
      assert temporal["duration"]["completeness"] == "complete"
    end
  end

  describe "recency_desc total order" do
    defp row(id, latest) do
      %{"id" => id, "latest_at" => latest, "temporal" => Temporal.row_temporal(nil, nil, [], latest, false)}
    end

    test "newest first, unknown before malformed at the tail, ties by ascending id" do
      rows = [
        row("b-tie", "2026-07-10T00:00:00Z"),
        row("z-malformed", "garbled"),
        row("a-unknown", nil),
        row("a-tie", "2026-07-10T00:00:00Z"),
        row("newest", "2026-07-11T00:00:00Z")
      ]

      sorted = Enum.sort_by(rows, &Temporal.recency_desc_key/1)

      assert Enum.map(sorted, & &1["id"]) == ["newest", "a-tie", "b-tie", "a-unknown", "z-malformed"]
    end

    test "offset timestamps order by instant, matching their UTC equivalents deterministically" do
      rows = [
        row("later-utc", "2026-07-10T03:00:00Z"),
        row("earlier-offset", "2026-07-10T04:00:00+02:00")
      ]

      sorted = Enum.sort_by(rows, &Temporal.recency_desc_key/1)
      assert Enum.map(sorted, & &1["id"]) == ["later-utc", "earlier-offset"]
    end

    test "rows without a temporal map fall back to the legacy latest_at field" do
      legacy = %{"id" => "legacy", "latest_at" => "2026-07-12T00:00:00Z"}
      sorted = Enum.sort_by([row("modern", "2026-07-11T00:00:00Z"), legacy], &Temporal.recency_desc_key/1)
      assert Enum.map(sorted, & &1["id"]) == ["legacy", "modern"]
    end

    test "default sort and vocabulary are pinned" do
      assert Temporal.default_sort() == "recency_desc"
      assert Temporal.sort_vocabulary() == ["recency_desc", "recency_asc", "duration_desc", "duration_asc"]
    end
  end

  test "marks a duration malformed when its end precedes its start" do
    workflow = %{"ts" => "2026-07-10T03:00:00Z"}
    finish = %{"ts" => "2026-07-10T02:00:00Z"}

    duration = Temporal.row_temporal(workflow, finish, [], finish["ts"], true)["duration"]

    assert duration == %{
             "ms" => nil,
             "basis" => "boundary_difference",
             "completeness" => "malformed"
           }
  end

  test "max_instant prefers the latest parseable instant over malformed and nil entries" do
    assert Temporal.max_instant([]) == nil

    assert Temporal.max_instant(["2026-07-10T03:00:00Z", "zzz-malformed", nil, "2026-07-10T04:00:00+02:00"]) ==
             "2026-07-10T03:00:00Z"
  end

  test "all-terminal ended_at selects the greatest valid instant over malformed strings" do
    subs = [
      sub("zzz-malformed", "completed"),
      sub("2026-07-10T04:00:00+02:00", "completed"),
      sub("2026-07-10T03:00:00Z", "completed")
    ]

    ended = Temporal.row_temporal(nil, nil, subs, "2026-07-10T03:00:00Z", true)["ended_at"]

    assert ended == %{
             "value" => "2026-07-10T03:00:00Z",
             "basis" => "terminal_subagent_lifecycle_ts",
             "completeness" => "complete"
           }
  end
end
