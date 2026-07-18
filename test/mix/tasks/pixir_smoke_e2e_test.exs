defmodule Mix.Tasks.Pixir.Smoke.E2eTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.E2e, as: SmokeTask

  test "--help exits before running the live smoke" do
    output =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--help"])) == :normal
      end)

    assert output =~ "mix pixir.smoke.e2e"
    assert output =~ "--probe-model"
  end

  test "--json --help is machine-readable" do
    payload =
      capture_io(fn ->
        assert catch_exit(SmokeTask.run(["--json", "--help"])) == :normal
      end)
      |> Jason.decode!()

    assert payload["ok"] == true
    assert payload["command"] == "mix pixir.smoke.e2e"
    assert payload["network"] == true
    assert "--help" in payload["options"]
  end

  test "e2e explicitly selects chatgpt_codex before its intentional Auth flow" do
    home = Path.join(System.tmp_dir!(), "pixir-e2e-profile-#{System.unique_integer([:positive])}")
    prior_home = System.get_env("PIXIR_HOME")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{
        "responses_backend" => %{
          "mode" => "open_responses",
          "base_url" => "http://localhost:11434",
          "auth" => %{"policy" => "none"}
        }
      })
    )

    System.put_env("PIXIR_HOME", home)
    prior_auth_state = :sys.get_state(Pixir.Auth)

    :sys.replace_state(Pixir.Auth, fn state ->
      %{state | credential: nil, env_api_key: nil}
    end)

    try do
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(SmokeTask.run(["--json", "--no-login"])) == {:shutdown, 1}
        end)

      assert output =~ "not_authenticated"
      refute output =~ "unsupported_backend"
    after
      :sys.replace_state(Pixir.Auth, fn _state -> prior_auth_state end)

      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end

  test "probe display model remains bound to the preflight resolution" do
    prior_model = Application.get_env(:pixir, :model)

    on_exit(fn ->
      if prior_model,
        do: Application.put_env(:pixir, :model, prior_model),
        else: Application.delete_env(:pixir, :model)
    end)

    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{
                 provider_intent: {:direct, Pixir.Provider},
                 request: %{},
                 provider_opts: [responses_backend: %{"mode" => "chatgpt_codex"}]
               },
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    Application.put_env(:pixir, :model, "gpt-mutated-after-preflight")

    assert SmokeTask.probe_model(resolved) == "gpt-5.4-mini"
  end

  test "malformed Config is labelled as a Responses preflight failure, not login" do
    home =
      Path.join(System.tmp_dir!(), "pixir-e2e-malformed-#{System.unique_integer([:positive])}")

    prior_home = System.get_env("PIXIR_HOME")
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.json"),
      Jason.encode!(%{"responses_backend" => %{"mode" => "future"}})
    )

    System.put_env("PIXIR_HOME", home)

    try do
      output =
        capture_io(:stderr, fn ->
          assert catch_exit(SmokeTask.run(["--json", "--no-login"])) == {:shutdown, 1}
        end)

      assert output =~ "responses backend preflight"
      assert output =~ "invalid_config"
      refute output =~ "could not sign in"
    after
      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end
end
