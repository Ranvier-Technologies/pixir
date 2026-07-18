defmodule Pixir.Provider.ResponsesAuthTest do
  use ExUnit.Case, async: false

  alias Pixir.Auth
  alias Pixir.Provider.ResponsesAuth
  alias Pixir.Providers.{ResolvedProviderRequest, ResponsesBackend}

  defmodule HeaderAuth do
    use GenServer

    def start_link(headers), do: GenServer.start_link(__MODULE__, headers)
    def init(headers), do: {:ok, headers}
    def handle_call(:request_headers, _from, headers), do: {:reply, {:ok, headers}, headers}
  end

  setup do
    name = :"responses_auth_#{System.unique_integer([:positive])}"

    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-responses-auth-#{System.unique_integer([:positive])}.json"
      )

    {:ok, _pid} =
      Auth.start_link(
        name: name,
        store_path: path,
        env_api_key: "api-key-sentinel",
        oauth: __MODULE__.NoOAuth
      )

    on_exit(fn -> File.rm_rf!(path) end)
    %{auth: name}
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  describe "ChatGPT delegation" do
    test "preserves the inherited API-key authorization header", %{auth: auth} do
      backend = ResponsesBackend.default()
      route = route!(backend)

      assert {:ok, resolved_auth} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)

      assert ResponsesAuth.headers(resolved_auth) == [
               {"authorization", "Bearer api-key-sentinel"}
             ]

      assert ResponsesAuth.summary(resolved_auth) == %{
               "policy" => "chatgpt_oauth_or_api_key",
               "header_names" => ["authorization"]
             }

      refute inspect(resolved_auth) =~ "api-key-sentinel"
    end

    test "preserves authorization/account-id order from the existing Auth seam" do
      backend = ResponsesBackend.default()
      route = route!(backend)

      headers = [
        {"authorization", "Bearer subscription-sentinel"},
        {"chatgpt-account-id", "account-sentinel"}
      ]

      {:ok, auth} = HeaderAuth.start_link(headers)

      assert {:ok, resolved_auth} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)
      assert ResponsesAuth.headers(resolved_auth) == headers

      inspected = inspect(resolved_auth)
      refute inspected =~ "subscription-sentinel"
      refute inspected =~ "account-sentinel"
    end
  end

  describe "generic policies" do
    test "none returns no headers without consulting Auth or the environment" do
      backend = open_backend!("https://none.example.invalid/v1/responses", :none)
      route = route!(backend)

      assert {:ok, resolved_auth} =
               ResponsesAuth.resolve(resolved!(backend), route,
                 auth: :must_not_be_called,
                 env_reader: fn _ -> raise "must not read environment" end
               )

      assert ResponsesAuth.headers(resolved_auth) == []

      assert ResponsesAuth.summary(resolved_auth) == %{
               "policy" => "none",
               "header_names" => []
             }
    end

    test "bearer_env reads exactly its named variable and emits only authorization" do
      backend =
        open_backend!(
          "https://bearer.example.invalid/v1/responses",
          {:bearer_env, "PIXIR_TEST_BEARER"}
        )

      route = route!(backend)
      test = self()

      env_reader = fn name ->
        send(test, {:env_read, name})
        "abc.DEF_123-~/+=="
      end

      assert {:ok, resolved_auth} =
               ResponsesAuth.resolve(resolved!(backend), route,
                 auth: :must_not_be_called,
                 env_reader: env_reader
               )

      assert_receive {:env_read, "PIXIR_TEST_BEARER"}

      assert ResponsesAuth.headers(resolved_auth) == [
               {"authorization", "Bearer abc.DEF_123-~/+=="}
             ]

      refute inspect(resolved_auth) =~ "abc.DEF_123"
      refute inspect(ResponsesAuth.summary(resolved_auth)) =~ "abc.DEF_123"
    end

    test "bearer material rotates only when a new auth value is resolved" do
      backend =
        open_backend!(
          "https://rotate.example.invalid/v1/responses",
          {:bearer_env, "PIXIR_ROTATING_BEARER"}
        )

      route = route!(backend)
      {:ok, tokens} = Agent.start_link(fn -> ["first-token", "second-token"] end)

      env_reader = fn "PIXIR_ROTATING_BEARER" ->
        Agent.get_and_update(tokens, fn [head | tail] -> {head, tail} end)
      end

      assert {:ok, first} =
               ResponsesAuth.resolve(resolved!(backend), route, env_reader: env_reader)

      first_headers = ResponsesAuth.headers(first)
      assert first_headers == [{"authorization", "Bearer first-token"}]
      assert ResponsesAuth.headers(first) == first_headers

      assert {:ok, second} =
               ResponsesAuth.resolve(resolved!(backend), route, env_reader: env_reader)

      assert ResponsesAuth.headers(second) == [{"authorization", "Bearer second-token"}]
    end
  end

  describe "bearer validation" do
    test "allows HTTPS and only the literal plain-HTTP loopback set" do
      positives = [
        "https://service.example.invalid/v1/responses",
        "http://localhost/v1/responses",
        "http://127.0.0.1/v1/responses",
        "http://127.255.255.254/v1/responses",
        "http://[::1]/v1/responses"
      ]

      Enum.each(positives, fn url ->
        backend = open_backend!(url, {:bearer_env, "PIXIR_TEST_BEARER"})

        assert {:ok, resolved_auth} =
                 ResponsesAuth.resolve(resolved!(backend), route!(backend),
                   env_reader: fn "PIXIR_TEST_BEARER" -> "valid-token" end
                 )

        assert ResponsesAuth.headers(resolved_auth) == [
                 {"authorization", "Bearer valid-token"}
               ]
      end)
    end

    test "rejects non-loopback and noncanonical plain-HTTP hosts without leaking them" do
      negatives = [
        "http://service.example.invalid/v1/responses",
        "http://0.0.0.0/v1/responses",
        "http://10.0.0.1/v1/responses",
        "http://192.168.1.1/v1/responses",
        "http://LOCALHOST/v1/responses",
        "http://localhost.example.invalid/v1/responses",
        "http://[::ffff:127.0.0.1]/v1/responses"
      ]

      Enum.each(negatives, fn url ->
        backend = open_backend!(url, {:bearer_env, "PIXIR_TEST_BEARER"})

        assert {:error, %{error: %{kind: :insecure_auth_transport}} = error} =
                 ResponsesAuth.resolve(resolved!(backend), route!(backend),
                   env_reader: fn _ -> raise "credential must not be read" end
                 )

        inspected = inspect(error)
        refute inspected =~ url
        refute inspected =~ URI.parse(url).host
      end)
    end

    test "rejects missing, malformed, non-ASCII, injected, and oversized values" do
      invalid_values = [
        nil,
        "",
        " ",
        "has whitespace",
        "line\nbreak",
        "carriage\rreturn",
        "tab\tvalue",
        <<0, 1, 2>>,
        <<127>>,
        <<255>>,
        "é",
        "=padding-first",
        "valid=then-invalid",
        "valid===suffix!",
        String.duplicate("a", 8_193)
      ]

      backend =
        open_backend!(
          "https://validation.example.invalid/v1/responses",
          {:bearer_env, "PIXIR_SECRET_BEARER"}
        )

      route = route!(backend)

      Enum.each(invalid_values, fn value ->
        assert {:error, %{error: %{kind: :not_authenticated}} = error} =
                 ResponsesAuth.resolve(resolved!(backend), route,
                   env_reader: fn "PIXIR_SECRET_BEARER" -> value end
                 )

        refute inspect(error) =~ "valid=then-invalid"
        refute inspect(error) =~ "valid===suffix!"
      end)
    end

    test "route/backend mismatch fails before reading the environment" do
      first =
        open_backend!(
          "https://first.example.invalid/v1/responses",
          {:bearer_env, "PIXIR_FIRST_BEARER"}
        )

      second =
        open_backend!(
          "https://second.example.invalid/v1/responses",
          {:bearer_env, "PIXIR_SECOND_BEARER"}
        )

      assert {:error, %{error: %{kind: :invalid_config}} = error} =
               ResponsesAuth.resolve(resolved!(second), route!(first),
                 env_reader: fn _ -> raise "credential must not be read" end
               )

      inspected = inspect(error)
      refute inspected =~ "first.example.invalid"
      refute inspected =~ "second.example.invalid"
    end
  end

  describe "legacy-origin confused-deputy defenses" do
    test "implicit Auth is rejected for a noncanonical legacy origin before Auth" do
      backend = ResponsesBackend.default()
      route = route!(backend, base_url: "https://legacy.example.invalid")

      assert {:error,
              %{error: %{kind: :invalid_config, details: %{reason: :explicit_auth_required}}} =
                error} = ResponsesAuth.resolve(resolved!(backend), route)

      refute inspect(error) =~ "legacy.example.invalid"
    end

    test "explicit API-key-only auth is allowed on external HTTPS" do
      backend = ResponsesBackend.default()
      route = route!(backend, base_url: "https://legacy.example.invalid")
      headers = [{"authorization", "Bearer legacy-api-key"}]
      {:ok, auth} = HeaderAuth.start_link(headers)

      assert {:ok, resolved_auth} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)
      assert ResponsesAuth.headers(resolved_auth) == headers
    end

    test "account-id is rejected on an external origin" do
      backend = ResponsesBackend.default()
      route = route!(backend, base_url: "https://legacy.example.invalid")

      {:ok, auth} =
        HeaderAuth.start_link([
          {"authorization", "Bearer legacy-subscription"},
          {"chatgpt-account-id", "account-secret"}
        ])

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{reason: :account_id_for_noncanonical_origin}
                }
              } = error} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)

      inspected = inspect(error)
      refute inspected =~ "legacy-subscription"
      refute inspected =~ "account-secret"
      refute inspected =~ "legacy.example.invalid"
    end

    test "external HTTP authorization is rejected and loopback HTTP is accepted" do
      backend = ResponsesBackend.default()
      headers = [{"authorization", "Bearer explicit-legacy"}]
      {:ok, auth} = HeaderAuth.start_link(headers)

      external_route = route!(backend, base_url: "http://legacy.example.invalid")

      assert {:error, %{error: %{kind: :insecure_auth_transport}} = error} =
               ResponsesAuth.resolve(resolved!(backend), external_route, auth: auth)

      refute inspect(error) =~ "explicit-legacy"
      refute inspect(error) =~ "legacy.example.invalid"

      loopback_route = route!(backend, base_url: "http://127.42.0.9")

      assert {:ok, resolved_auth} =
               ResponsesAuth.resolve(resolved!(backend), loopback_route, auth: auth)

      assert ResponsesAuth.headers(resolved_auth) == headers
    end

    test "empty explicit auth remains credential-free" do
      backend = ResponsesBackend.default()
      route = route!(backend, base_url: "http://legacy.example.invalid")
      {:ok, auth} = HeaderAuth.start_link([])

      assert {:ok, resolved_auth} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)
      assert ResponsesAuth.headers(resolved_auth) == []
    end

    test "duplicate, unexpected, unsafe, and orphan account-id headers are rejected" do
      invalid_headers = [
        [
          {"authorization", "Bearer first"},
          {"authorization", "Bearer second"}
        ],
        [{"x-secret-header", "hidden"}],
        [{"authorization", "Bearer safe\r\ninjected: bad"}],
        [{"chatgpt-account-id", "orphan"}]
      ]

      backend = ResponsesBackend.default()
      route = route!(backend)

      Enum.each(invalid_headers, fn headers ->
        {:ok, auth} = HeaderAuth.start_link(headers)

        assert {:error,
                %{error: %{kind: :invalid_config, details: %{reason: :invalid_auth_headers}}} =
                  error} = ResponsesAuth.resolve(resolved!(backend), route, auth: auth)

        refute inspect(error) =~ "hidden"
        refute inspect(error) =~ "injected"
        refute inspect(error) =~ "orphan"
      end)
    end
  end

  defp open_backend!(url, auth_policy) do
    auth =
      case auth_policy do
        :none -> %{"policy" => "none"}
        {:bearer_env, env_var} -> %{"policy" => "bearer_env", "env_var" => env_var}
      end

    assert {:ok, backend} =
             ResponsesBackend.resolve(
               %{
                 "mode" => "open_responses",
                 "responses_url" => url,
                 "auth" => auth
               },
               source: :provider_opts
             )

    backend
  end

  defp route!(backend, opts \\ []) do
    assert {:ok, routing} =
             apply(Pixir.Provider.ResponsesRouting, :resolve, [backend, opts])

    routing
  end

  defp resolved!(backend) do
    ResolvedProviderRequest.new(%{
      provider: Pixir.Provider,
      model: "test-model",
      dialect: :responses,
      capabilities: %{
        reasoning_dialect: nil,
        prompt_cache: :prompt_cache_key,
        prompt_contract_version: nil,
        tool_dialect: :responses,
        hosted_tools: true
      },
      responses_backend: backend,
      provider_defaults: %{
        max_retries: 0,
        stream_idle_timeout_ms: 1_000,
        reasoning_effort: nil,
        text_verbosity: nil,
        web_search: nil
      },
      source_evidence: %{
        provider: :direct,
        model: :request,
        responses_backend: :provider_opts
      }
    })
  end
end
