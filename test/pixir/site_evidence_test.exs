defmodule Pixir.SiteEvidenceTest do
  use ExUnit.Case, async: true

  alias Pixir.{Event, Log}

  defmodule ForbiddenRunner do
    def run(_, _, _, _), do: raise("the website dry-run must not execute agent work")
  end

  test "the downloadable first-worker spec passes the real dry-run contract" do
    sample = Path.expand("../../site/public/examples/first-worker.json", __DIR__)

    assert {:ok, %{exit_code: 0, payload: payload}} =
             Pixir.Delegate.CLIContract.run(
               ["--spec", sample, "--dry-run", "--json", "--timeout-ms", "150000"],
               runner: ForbiddenRunner
             )

    assert payload["command_ok"]
    refute payload["would_reject"]
    assert payload["dry_run"]
  end

  test "the site's downloadable evidence is canonical, replayable NDJSON" do
    sample = Path.expand("../../site/public/examples/session.ndjson", __DIR__)
    sid = "20260906T120000-example"

    workspace =
      Path.join(System.tmp_dir!(), "site-evidence-#{System.unique_integer([:positive])}")

    log_path = Log.path(sid, workspace: workspace)
    File.mkdir_p!(Path.dirname(log_path))
    on_exit(fn -> File.rm_rf!(workspace) end)
    File.cp!(sample, log_path)

    assert {:ok, events} = Log.fold(sid, workspace: workspace)
    assert Enum.map(events, & &1.type) == [:user_message, :provider_usage, :assistant_message]
    assert Enum.map(events, & &1.seq) == [1, 2, 3]
    assert Enum.all?(events, &(Event.canonical?(&1) and &1.session_id == sid))
    assert Enum.all?(events, &match?({:ok, _, _}, DateTime.from_iso8601(&1.ts)))
    assert Enum.at(events, 1).data["usage_summary"]["cached_tokens"] == 1190
    assert List.last(events).data["text"] == "README summary complete."
  end
end
