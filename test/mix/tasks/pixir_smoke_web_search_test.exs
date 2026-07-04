defmodule Mix.Tasks.Pixir.Smoke.WebSearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.WebSearch, as: SmokeTask

  test "--json --help is machine-readable and exits before auth/network" do
    payload =
      capture_io(fn ->
        assert SmokeTask.run(["--json", "--help"]) == :ok
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.web_search"
    assert payload["network"] == true
    assert "--dry-run" in payload["options"]
    assert "web_search_call_observed" in payload["proof_states"]
  end

  test "--dry-run --json shows exact hosted web_search request shape without network" do
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
    assert payload["search_context_size"] == "low"
    assert payload["would_send"]["store"] == false
    assert payload["would_send"]["stream"] == true
    assert "web_search_call.action.sources" in payload["would_send"]["include"]

    assert %{"type" => "web_search", "search_context_size" => "low"} in payload["would_send"][
             "tools"
           ]
  end

  test "invalid search context size is structured and actionable" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "--search-context-size", "huge"])) ==
                 {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "invalid_search_context_size"
    assert payload["error"]["details"]["allowed"] == ["low", "medium", "high"]
    assert [next | _] = payload["next_steps"]
    assert next =~ "--search-context-size low"
  end

  test "unexpected positional args are structured and actionable" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "surprise"])) == {:shutdown, 1}
      end)
      |> Jason.decode!()

    assert payload["ok"] == false
    assert payload["error"]["kind"] == "unexpected_args"
    assert payload["error"]["details"]["argv"] == ["surprise"]
    assert [next | _] = payload["next_steps"]
    assert next =~ "--help"
  end
end
