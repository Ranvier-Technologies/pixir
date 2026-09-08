defmodule Pixir.ModelsRefreshTest do
  use ExUnit.Case, async: true

  alias Pixir.{Auth, ModelsRefresh}
  alias Pixir.Providers.ErrBody

  setup do
    # Randomised suffix, not just `System.unique_integer/1`: that counter restarts low
    # on every node, so a crashed suite can leave a dirty dir the next run reuses. A
    # leftover auth store inside it would restore subscription-over-key (#464).
    dir =
      Path.join(
        System.tmp_dir!(),
        "pixir-models-refresh-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    config_path = Path.join(dir, "config.json")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, config_path: config_path}
  end

  test "refreshes both providers, computes diffs, preserves foreign keys, and stamps UTC", %{
    dir: dir,
    config_path: path
  } do
    File.write!(
      path,
      Jason.encode!(%{
        "foreign" => %{"keep" => true},
        "models" => ["gpt-5.5", "gpt-old"],
        "anthropic_models" => ["claude-fable-5", "claude-old"]
      })
    )

    auth = start_auth(dir, "sk-openai")
    now = ~U[2026-03-10 12:34:56Z]

    http = fn request ->
      cond do
        request.url =~ "openai.com" ->
          assert {"authorization", "Bearer sk-openai"} in request.headers
          {:ok, %{status: 200, body: models_body(["gpt-5.5", "gpt-new"])}}

        request.url =~ "anthropic.com" ->
          assert {"x-api-key", "sk-anthropic"} in request.headers
          assert {"anthropic-version", "2023-06-01"} in request.headers
          {:ok, %{status: 200, body: models_body(["claude-fable-5", "claude-new"])}}
      end
    end

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: auth,
               env: fn "ANTHROPIC_API_KEY" -> "sk-anthropic" end,
               http: http,
               now: now
             )

    assert result["wrote_config"]
    assert result["refreshed_at"] == "2026-03-10T12:34:56Z"
    assert {:ok, _, 0} = DateTime.from_iso8601(result["refreshed_at"])

    assert result["providers"]["openai"]["added"] == ["gpt-new"]
    assert result["providers"]["openai"]["removed"] == ["gpt-old"]
    assert result["providers"]["anthropic"]["added"] == ["claude-new"]
    assert result["providers"]["anthropic"]["removed"] == ["claude-old"]

    written = path |> File.read!() |> Jason.decode!()
    assert written["foreign"] == %{"keep" => true}
    assert written["models"] == ["gpt-5.5", "gpt-new"]
    assert written["anthropic_models"] == ["claude-fable-5", "claude-new"]
    assert written["models_refreshed_at"] == "2026-03-10T12:34:56Z"
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "oauth skips OpenAI while an Anthropic success updates only its owned key", %{
    dir: dir,
    config_path: path
  } do
    original = %{
      "models" => ["gpt-existing"],
      "anthropic_models" => ["claude-existing"],
      "foreign" => 7
    }

    File.write!(path, Jason.encode!(original))
    auth = start_subscription_auth(dir)

    http = fn request ->
      refute request.url =~ "openai.com"
      {:ok, %{status: 200, body: models_body(["claude-fable-5", "claude-refreshed"])}}
    end

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: auth,
               env: fn "ANTHROPIC_API_KEY" -> "anthropic-key" end,
               http: http
             )

    assert %{
             "status" => "skipped",
             "reason" => "auth_kind_unsupported_for_models_endpoint",
             "next_actions" => actions
           } = result["providers"]["openai"]

    assert is_list(actions)

    written = path |> File.read!() |> Jason.decode!()
    assert written["models"] == original["models"]
    assert written["anthropic_models"] == ["claude-fable-5", "claude-refreshed"]
    assert written["foreign"] == 7
  end

  test "oauth skip gives bounded manual guidance without HTTP or config mutation", %{
    dir: dir,
    config_path: path
  } do
    original =
      Jason.encode!(
        %{
          "model" => "gpt-5.5",
          "models" => ["gpt-existing"],
          "models_refreshed_at" => "2026-01-02T03:04:05Z",
          "foreign" => %{"keep" => true}
        },
        pretty: true
      )

    File.write!(path, original)
    caller = self()
    request_marker = make_ref()

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_subscription_auth(dir),
               env: fn _ -> nil end,
               http: fn _ ->
                 send(caller, request_marker)
                 {:error, :unexpected_http_request}
               end
             )

    refute_received ^request_marker
    assert result["wrote_config"] == false
    assert File.read!(path) == original

    assert %{
             "status" => "skipped",
             "reason" => "auth_kind_unsupported_for_models_endpoint",
             "next_actions" => actions
           } = result["providers"]["openai"]

    assert length(actions) == 2
    assert Enum.all?(actions, &(is_binary(&1) and byte_size(&1) <= 256))
    assert Enum.all?(actions, &String.contains?(&1, "availability"))
    assert Enum.any?(actions, &String.contains?(&1, "config.json"))
    assert Enum.any?(actions, &String.contains?(&1, "\"models\""))
    assert Enum.any?(actions, &String.contains?(&1, "replaces"))
    assert Enum.any?(actions, &String.contains?(&1, "explicit model override"))
    assert Enum.any?(actions, &String.contains?(&1, "PIXIR_MODEL"))
  end

  test "non-200 is bounded and fail-closed with config byte-identical", %{
    dir: dir,
    config_path: path
  } do
    original = Jason.encode!(%{"models" => ["gpt-existing"], "foreign" => true}, pretty: true)
    File.write!(path, original)
    auth = start_auth(dir, "sk-openai")
    oversized = String.duplicate("x", ErrBody.max_bytes() * 2)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: auth,
               env: fn _ -> nil end,
               http: fn _ -> {:ok, %{status: 503, body: oversized}} end
             )

    openai = result["providers"]["openai"]
    assert openai["status"] == "error"
    assert openai["kind"] == "provider_http_error"
    assert openai["status_code"] == 503
    assert byte_size(openai["err_body"]) == ErrBody.max_bytes()
    assert openai["err_body_truncated"] == true
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "non-200 marker records only actual byte drops at the exact cap", %{
    dir: dir,
    config_path: path
  } do
    original = Jason.encode!(%{"models" => ["gpt-existing"], "foreign" => true}, pretty: true)
    auth = start_auth(dir, "sk-openai")
    cap = ErrBody.max_bytes()

    for {received_bytes, expected_truncated} <- [
          {cap - 1, false},
          {cap, false},
          {cap + 1, true}
        ] do
      File.write!(path, original)
      body = String.duplicate("x", received_bytes)

      assert {:ok, result} =
               ModelsRefresh.refresh(
                 config_path: path,
                 auth: auth,
                 env: fn _ -> nil end,
                 http: fn _ -> {:ok, %{status: 503, body: body}} end
               )

      openai = result["providers"]["openai"]
      expected_body = binary_part(body, 0, min(received_bytes, cap))

      assert openai["err_body"] == expected_body
      assert byte_size(openai["err_body"]) <= cap
      assert Map.has_key?(openai, "err_body_truncated") == expected_truncated

      if expected_truncated do
        assert openai["err_body_truncated"] == true
      end

      assert result["wrote_config"] == false
      assert File.read!(path) == original
    end
  end

  test "garbage JSON response is fail-closed", %{dir: dir, config_path: path} do
    original = ~s({"models":["gpt-existing"],"foreign":"same"})
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth(dir, "sk-openai"),
               env: fn _ -> nil end,
               http: fn _ -> {:ok, %{status: 200, body: "not-json"}} end
             )

    assert result["providers"]["openai"]["kind"] == "invalid_json"
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "both endpoint failures leave config byte-identical", %{dir: dir, config_path: path} do
    original = "{\n  \"models\": [\"gpt-existing\"],\n  \"foreign\": \"untouched\"\n}\n"
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth(dir, "sk-openai"),
               env: fn "ANTHROPIC_API_KEY" -> "sk-anthropic" end,
               http: fn request ->
                 if request.url =~ "openai.com" do
                   {:error, :openai_down}
                 else
                   {:ok, %{status: 500, body: "anthropic down"}}
                 end
               end
             )

    assert result["providers"]["openai"]["status"] == "error"
    assert result["providers"]["anthropic"]["status"] == "error"
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "both providers skipped do not call HTTP or touch config", %{
    dir: dir,
    config_path: path
  } do
    original = "{\n  \"foreign\": true\n}\n"
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth(dir, nil),
               env: fn _ -> nil end,
               http: fn _ -> flunk("HTTP must not be called without credentials") end
             )

    assert result["providers"]["openai"]["reason"] == "no_credential"
    assert result["providers"]["anthropic"]["reason"] == "no_credential"
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "auth store paths are private so a stale credential cannot leak in", %{
    dir: dir,
    config_path: path
  } do
    original = "{\n  \"foreign\": true\n}\n"
    File.write!(path, original)

    # Simulate the cross-run collision behind #464 without ever writing outside this
    # test's own tmp dir. `prior` is a previous run's dir and `current` is this run's;
    # `System.unique_integer/1` restarts low on every node, so both runs can hand the
    # helper the SAME auth name. A run that leaked its store into a process-wide root
    # would make the second Auth inherit the first's subscription credential.
    #
    # The failure this pins is not "no credential": it is a test that DOES supply an
    # API key still ending up on the subscription skip branch, where err_body is nil.
    name = auth_name()
    prior = Path.join(dir, "prior-run")
    current = Path.join(dir, "current-run")
    File.mkdir_p!(prior)
    File.mkdir_p!(current)

    # The prior run persists a real subscription credential through the real helper.
    prior_auth_name = :"prior_#{name}"
    prior_auth = start_auth(prior, prior_auth_name, nil)

    :ok =
      Auth.set_credential(prior_auth, %{
        kind: :subscription,
        access_token: "oauth-token",
        refresh_token: "refresh-token",
        account_id: "account",
        expires_at: System.system_time(:millisecond) + 60_000,
        obtained_at: System.system_time(:millisecond)
      })

    # It landed in the prior run's dir, and nowhere else.
    assert File.exists?(auth_store_path(prior, prior_auth_name))

    # Keep the leftover under `prior`, then prove both halves of resolution: that file is
    # not read by the current Auth, while a second leftover planted under `current` is.
    # Pixir.Auth intentionally gives a stored subscription precedence over env_api_key,
    # so planting under `current` and expecting :api_key would assert the wrong product
    # semantics. The two-name probe below instead fails against the pre-fix shared-root
    # helper and cannot pass merely because both planted files were ignored.
    leftover = File.read!(auth_store_path(prior, prior_auth_name))
    File.write!(auth_store_path(prior, name), leftover)

    auth = start_auth(current, name, "sk-openai")

    status = Auth.status(auth)
    assert status.authenticated?
    assert status.kind == :api_key

    resolved_probe_name = auth_name()
    File.write!(auth_store_path(current, resolved_probe_name), leftover)
    resolved_probe_auth = start_auth(current, resolved_probe_name, "sk-probe")

    resolved_probe_status = Auth.status(resolved_probe_auth)
    assert resolved_probe_status.authenticated?
    assert resolved_probe_status.kind == :subscription

    # Drive one real refresh down the 503 path. Under the bug this provider entry is a
    # "skipped" map and err_body is nil; the assertion below is the exact field #464
    # reported missing.
    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: auth,
               env: fn _ -> nil end,
               http: fn request ->
                 assert {"authorization", "Bearer sk-openai"} in request.headers
                 {:ok, %{status: 503, body: "upstream unavailable"}}
               end
             )

    openai = result["providers"]["openai"]
    assert openai["status"] == "error"
    assert openai["kind"] == "provider_http_error"
    assert openai["status_code"] == 503
    assert openai["err_body"] == "upstream unavailable"
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "catalog reports built-in versus override sources without HTTP", %{config_path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "anthropic_models" => ["claude-refreshed"],
        "models_refreshed_at" => "2026-01-02T03:04:05Z"
      })
    )

    assert {:ok, catalog} = ModelsRefresh.catalog(config_path: path)
    assert catalog["providers"]["openai"]["source"] == "built_in"
    assert "gpt-5.6-sol" in catalog["providers"]["openai"]["models"]
    assert "gpt-6-astra" in catalog["providers"]["openai"]["models"]
    assert catalog["providers"]["anthropic"]["source"] == "config_override"
    assert "claude-refreshed" in catalog["providers"]["anthropic"]["models"]
    assert catalog["models_refreshed_at"] == "2026-01-02T03:04:05Z"
  end

  defp start_auth(dir, key), do: start_auth(dir, auth_name(), key)

  # The store path must live under this test's own `dir` (removed on exit), never
  # the shared tmp root: `System.unique_integer/1` restarts low on every node, so a
  # run reusing a past run's integer would load that run's leftover auth.json and
  # inherit a subscription credential the test never set (#464). `auth_store_path/2`
  # is the single resolution point pinned by the "stale credential" test below.
  defp start_auth(dir, name, key) do
    path = auth_store_path(dir, name)
    {:ok, _pid} = Auth.start_link(name: name, store_path: path, env_api_key: key)
    name
  end

  defp auth_name, do: :"models_auth_#{System.unique_integer([:positive])}"

  defp auth_store_path(dir, name), do: Path.join(dir, "#{name}.json")

  defp start_subscription_auth(dir) do
    auth = start_auth(dir, nil)

    :ok =
      Auth.set_credential(auth, %{
        kind: :subscription,
        access_token: "oauth-token",
        refresh_token: "refresh-token",
        account_id: "account",
        expires_at: System.system_time(:millisecond) + 60_000,
        obtained_at: System.system_time(:millisecond)
      })

    auth
  end

  defp models_body(ids) do
    Jason.encode!(%{"data" => Enum.map(ids, &%{"id" => &1})})
  end
end
