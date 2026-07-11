defmodule Pixir.ModelsRefreshTest do
  use ExUnit.Case, async: true

  alias Pixir.{Auth, ModelsRefresh}
  alias Pixir.Providers.ErrBody

  setup do
    dir =
      Path.join(System.tmp_dir!(), "pixir-models-refresh-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    config_path = Path.join(dir, "config.json")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, config_path: config_path}
  end

  test "refreshes both providers, computes diffs, preserves foreign keys, and stamps UTC", %{
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

    auth = start_auth("sk-openai")
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
    config_path: path
  } do
    original = %{
      "models" => ["gpt-existing"],
      "anthropic_models" => ["claude-existing"],
      "foreign" => 7
    }

    File.write!(path, Jason.encode!(original))
    auth = start_subscription_auth()

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

    assert result["providers"]["openai"] == %{
             "status" => "skipped",
             "reason" => "auth_kind_unsupported_for_models_endpoint"
           }

    written = path |> File.read!() |> Jason.decode!()
    assert written["models"] == original["models"]
    assert written["anthropic_models"] == ["claude-fable-5", "claude-refreshed"]
    assert written["foreign"] == 7
  end

  test "non-200 is bounded and fail-closed with config byte-identical", %{config_path: path} do
    original = Jason.encode!(%{"models" => ["gpt-existing"], "foreign" => true}, pretty: true)
    File.write!(path, original)
    auth = start_auth("sk-openai")
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

  test "garbage JSON response is fail-closed", %{config_path: path} do
    original = ~s({"models":["gpt-existing"],"foreign":"same"})
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth("sk-openai"),
               env: fn _ -> nil end,
               http: fn _ -> {:ok, %{status: 200, body: "not-json"}} end
             )

    assert result["providers"]["openai"]["kind"] == "invalid_json"
    assert result["wrote_config"] == false
    assert File.read!(path) == original
  end

  test "both endpoint failures leave config byte-identical", %{config_path: path} do
    original = "{\n  \"models\": [\"gpt-existing\"],\n  \"foreign\": \"untouched\"\n}\n"
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth("sk-openai"),
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

  test "both providers skipped do not call HTTP or touch config", %{config_path: path} do
    original = "{\n  \"foreign\": true\n}\n"
    File.write!(path, original)

    assert {:ok, result} =
             ModelsRefresh.refresh(
               config_path: path,
               auth: start_auth(nil),
               env: fn _ -> nil end,
               http: fn _ -> flunk("HTTP must not be called without credentials") end
             )

    assert result["providers"]["openai"]["reason"] == "no_credential"
    assert result["providers"]["anthropic"]["reason"] == "no_credential"
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
    assert catalog["providers"]["anthropic"]["source"] == "config_override"
    assert "claude-refreshed" in catalog["providers"]["anthropic"]["models"]
    assert catalog["models_refreshed_at"] == "2026-01-02T03:04:05Z"
  end

  defp start_auth(key) do
    name = :"models_auth_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.json")
    {:ok, _pid} = Auth.start_link(name: name, store_path: path, env_api_key: key)
    name
  end

  defp start_subscription_auth do
    auth = start_auth(nil)

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
