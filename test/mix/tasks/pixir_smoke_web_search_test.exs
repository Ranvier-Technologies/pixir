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

  test "real path lets Provider profile preflight govern before Auth" do
    for {profile, kind} <- profile_cases() do
      with_profile(profile, fn ->
        payload =
          capture_io(fn ->
            assert catch_exit(SmokeTask.run(["--json"])) == {:shutdown, 1}
          end)
          |> Jason.decode!()

        assert payload["ok"] == false
        assert payload["schema_version"] == 1
        assert payload["command"] == "mix pixir.smoke.web_search"
        assert payload["error"]["kind"] == kind
        assert payload["next_steps"] != []
      end)
    end
  end

  test "dry-run projects malformed and staged-open preflight errors without crashing" do
    for {profile, kind} <- profile_cases() do
      with_profile(profile, fn ->
        payload =
          capture_io(fn ->
            assert catch_exit(SmokeTask.run(["--dry-run", "--json"])) == {:shutdown, 1}
          end)
          |> Jason.decode!()

        assert payload["ok"] == false
        assert payload["schema_version"] == 1
        assert payload["command"] == "mix pixir.smoke.web_search"
        assert payload["error"]["kind"] == kind
        assert payload["error"]["message"] != ""
        assert map_size(payload["error"]["details"]) == 2
        assert payload["next_steps"] != []
        refute inspect(payload) =~ "KeyError"
      end)
    end
  end

  test "dry-run without --json keeps malformed and staged-open errors human-readable" do
    for {profile, kind} <- profile_cases() do
      with_profile(profile, fn ->
        test = self()

        stderr =
          capture_io(:stderr, fn ->
            stdout =
              capture_io(fn ->
                assert catch_exit(SmokeTask.run(["--dry-run"])) == {:shutdown, 1}
              end)

            send(test, {:human_dry_run_stdout, stdout})
          end)

        assert_receive {:human_dry_run_stdout, ""}
        assert stderr =~ kind
        assert stderr =~ "next:"
        refute stderr =~ ~s({"ok":false)
        refute stderr =~ "KeyError"
      end)
    end
  end

  test "preview error normalization accepts canonical nested and flat forms" do
    error = %{
      kind: :invalid_config,
      message: "invalid preview",
      details: %{field: :responses_backend, reason: :invalid_type}
    }

    assert {:ok, ^error} = SmokeTask.normalize_preview_error({:error, %{error: error}})
    assert {:ok, ^error} = SmokeTask.normalize_preview_error({:error, error})
    assert :error = SmokeTask.normalize_preview_error({:error, %{kind: :invalid_config}})
  end

  defp profile_cases do
    [
      {%{"mode" => "future"}, "invalid_config"},
      {%{
         "mode" => "open_responses",
         "responses_url" => "https://vendor.example/v1/responses",
         "auth" => %{"policy" => "none"}
       }, "unsupported_backend_capability"}
    ]
  end

  defp with_profile(profile, fun) do
    home =
      Path.join(System.tmp_dir!(), "pixir-search-profile-#{System.unique_integer([:positive])}")

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
