defmodule Pixir.Subagents.GCTest do
  use ExUnit.Case, async: true

  alias Pixir.{Paths, Subagents.GC}

  test "plan refuses a symlinked sessions directory without listing or mutating its target" do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-subagents-gc-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(root) end)

    outside_name = "outside-secret-name.ndjson"
    outside_log = Path.join(outside, outside_name)
    File.write!(outside_log, "outside-secret-bytes")
    File.mkdir_p!(Paths.project_root(workspace))
    File.ln_s!(outside, Paths.sessions_dir(workspace))

    assert {:error, %{"kind" => "subagent_gc_evidence_error"} = error} =
             GC.plan(workspace: workspace)

    refute inspect(error) =~ outside_name
    refute inspect(error) =~ "outside-secret-bytes"
    assert File.read!(outside_log) == "outside-secret-bytes"
  end
end
