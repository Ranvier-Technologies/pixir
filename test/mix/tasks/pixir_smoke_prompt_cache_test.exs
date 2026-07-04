defmodule Mix.Tasks.Pixir.Smoke.PromptCacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.PromptCache, as: SmokeTask

  test "--json --help is machine-readable and exits before auth/network" do
    payload =
      capture_io(fn ->
        assert SmokeTask.run(["--json", "--help"]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.prompt_cache"
    assert payload["network"] == true
    assert "--dry-run" in payload["options"]
    assert "usage_reported" in payload["proof_states"]
  end

  test "--dry-run --json plans two stable-prefix requests without network" do
    payload =
      capture_io(fn ->
        assert SmokeTask.run(["--dry-run", "--json"]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["mode"] == "dry_run"
    assert payload["network"] == false
    assert payload["model"] == "gpt-5.5"
    assert payload["reasoning_effort"] == "low"
    assert payload["estimated_real_network_requests"] == 2
    assert payload["stable_prefix_words"] > 1_000
    assert payload["would_send"]["prompt_cache_key"] == true
    assert payload["would_send"]["store"] == false
  end

  test "invalid retention is structured and actionable" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "--prompt-cache-retention", "forever"])) ==
                 {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_prompt_cache_retention"
    assert payload["error"]["details"]["allowed"] == ["24h", "in_memory"]
  end
end
