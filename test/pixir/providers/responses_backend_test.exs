defmodule Pixir.Providers.ResponsesBackendTest do
  use ExUnit.Case, async: true

  alias Pixir.Providers.ResponsesBackend

  test "default and explicit chatgpt_codex expose only safe capabilities" do
    default = ResponsesBackend.default()

    assert ResponsesBackend.mode(default) == :chatgpt_codex
    assert ResponsesBackend.source(default) == :default
    refute ResponsesBackend.explicit?(default)
    assert ResponsesBackend.endpoint(default) == :default
    assert ResponsesBackend.auth_policy(default) == :chatgpt_oauth_or_api_key
    assert ResponsesBackend.transports(default) == [:websocket, :http_sse]
    assert ResponsesBackend.activation_status(default) == :ok

    assert {:ok, explicit} =
             ResponsesBackend.resolve(%{"mode" => "chatgpt_codex"}, source: :provider_opts)

    assert ResponsesBackend.source(explicit) == :provider_opts
    assert ResponsesBackend.explicit?(explicit)

    extensions = ResponsesBackend.request_extensions(explicit)
    assert MapSet.member?(extensions, :prompt_cache_key)
    assert MapSet.member?(extensions, :reasoning_encrypted_content)
    assert MapSet.member?(extensions, :hosted_tool_includes)
    refute MapSet.member?(extensions, :prompt_cache_retention)
  end

  test "resolve is idempotent only for semantically valid opaque descriptors" do
    backend = ResponsesBackend.default()
    assert {:ok, ^backend} = ResponsesBackend.resolve(backend)

    fabricated = struct(backend, transports: [])

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :responses_backend, reason: :invalid_type}
              }
            }} = ResponsesBackend.resolve(fabricated)

    assert {:error, %{error: %{kind: :invalid_config}}} =
             ResponsesBackend.activation_status(fabricated)
  end

  test "struct-shaped profiles and nested values fail closed without enumeration" do
    sentinel = "https://SECRET.example/v1/responses"
    uri = URI.parse(sentinel)

    profiles = [
      uri,
      DateTime.utc_now(),
      MapSet.new(),
      MapSet.new([{"mode", "chatgpt_codex"}]),
      %{"mode" => uri},
      %{
        "mode" => "open_responses",
        "base_url" => "http://localhost:11434",
        "auth" => uri
      }
    ]

    for profile <- profiles do
      assert {:error, %{error: %{kind: :invalid_config, details: %{field: field}}} = payload} =
               ResponsesBackend.resolve(profile)

      assert field in [:responses_backend, :auth]
      refute inspect(payload) =~ sentinel
      assert {:ok, _json} = Jason.encode(payload)
    end

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :responses_backend, reason: :invalid_type}
              }
            }} =
             ResponsesBackend.resolve(%{
               "mode" => "open_responses",
               "base_url" => uri,
               "auth" => %{"policy" => "none"}
             })

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :auth, reason: :invalid_type}
              }
            }} =
             ResponsesBackend.resolve(%{
               "mode" => "open_responses",
               "base_url" => "https://vendor.example",
               "auth" => %{"policy" => "none", "extra" => DateTime.utc_now()}
             })
  end

  test "valid open profiles preserve exact endpoints but redact diagnostic and Inspect projections" do
    endpoint = "https://vendor.example/api/v1/responses"

    assert {:ok, backend} =
             ResponsesBackend.resolve(%{
               "mode" => "open_responses",
               "responses_url" => endpoint,
               "auth" => %{"policy" => "bearer_env", "env_var" => "VENDOR_API_KEY"}
             })

    assert ResponsesBackend.mode(backend) == :open_responses
    assert ResponsesBackend.source(backend) == :config
    assert ResponsesBackend.endpoint(backend) == {:responses_url, endpoint}
    assert ResponsesBackend.auth_policy(backend) == {:bearer_env, "VENDOR_API_KEY"}
    assert ResponsesBackend.transports(backend) == [:http_sse]
    assert ResponsesBackend.request_extensions(backend) == MapSet.new()

    assert ResponsesBackend.activation_status(backend) == :ok

    projection = inspect(backend)
    refute projection =~ endpoint
    refute projection =~ "VENDOR_API_KEY="

    summary = ResponsesBackend.summary(backend)
    assert summary["endpoint_kind"] == "responses_url"

    assert summary["auth_policy"] == %{
             "policy" => "bearer_env",
             "env_var" => "VENDOR_API_KEY"
           }

    refute inspect(summary) =~ endpoint
  end

  test "Inspect fails closed for every fabricated backend field" do
    sentinel = "FABRICATED_BACKEND_SECRET_SENTINEL"
    default = ResponsesBackend.default()

    fabricated = [
      struct(default, mode: sentinel),
      struct(default, endpoint: {sentinel, sentinel}),
      struct(default, auth_policy: {:bearer_env, sentinel}),
      struct(default, request_extensions: [sentinel])
    ]

    for backend <- fabricated do
      assert ResponsesBackend.safe_summary(backend) == :invalid
      assert ResponsesBackend.summary(backend) == :invalid
      projection = inspect(backend)
      assert projection == "#ResponsesBackend<:invalid>"
      refute projection =~ sentinel
      refute projection =~ "Inspect.Error"
    end

    valid = ResponsesBackend.default()
    assert ResponsesBackend.safe_summary(valid) == ResponsesBackend.summary(valid)
    assert inspect(valid) =~ inspect(ResponsesBackend.summary(valid))
    refute inspect(valid) =~ ":invalid"
  end

  test "accepts exact base and response URL boundary forms" do
    valid = [
      {:base_url, "http://localhost"},
      {:base_url, "http://localhost/"},
      {:base_url, "http://127.0.0.1:11434"},
      {:base_url, "http://[::1]:11434/"},
      {:base_url, "https://a.example"},
      {:base_url, "https://0xvendor.example"},
      {:base_url, "https://dead.beef"},
      {:responses_url, "https://vendor.example/v1/responses"},
      {:responses_url, "http://127.0.0.1/a%2Fb"},
      {:responses_url, "https://a-b.example/path"}
    ]

    for {kind, url} <- valid do
      profile =
        %{"mode" => "open_responses", "auth" => %{"policy" => "none"}}
        |> Map.put(Atom.to_string(kind), url)

      assert {:ok, backend} = ResponsesBackend.resolve(profile), inspect({kind, url})
      assert ResponsesBackend.endpoint(backend) == {kind, url}
    end
  end

  test "rejects ambiguous, unsafe, or noncanonical endpoint forms" do
    invalid = [
      {:base_url, ""},
      {:base_url, " localhost "},
      {:base_url, "localhost:11434"},
      {:base_url, "/relative"},
      {:base_url, "ftp://example.com"},
      {:base_url, "HTTPS://example.com"},
      {:base_url, "https://user@example.com"},
      {:base_url, "https://example.com?x=1"},
      {:base_url, "https://example.com#frag"},
      {:base_url, "https://example.com\\path"},
      {:base_url, "https://example.com/path"},
      {:base_url, "https://127.0.0.01"},
      {:base_url, "https://2130706433"},
      {:base_url, "https://0x7f000001"},
      {:base_url, "https://0x7f.0x0.0x0.0x1"},
      {:base_url, "https://0x7f.1"},
      {:base_url, "https://example.com."},
      {:base_url, "https://bad_host.example"},
      {:base_url, "https://example..com"},
      {:base_url, "https://%65xample.com"},
      {:base_url, "https://example.com:0"},
      {:base_url, "https://example.com:00080"},
      {:base_url, "https://example.com:65536"},
      {:base_url, "https://example.com:"},
      {:base_url, "https://example.com:+80"},
      {:base_url, "https://example.com:-1"},
      {:base_url, "https://example.com:1e2"},
      {:base_url, "https://example.com:http"},
      {:base_url, "https://example.com:８０"},
      {:responses_url, "https://example.com"},
      {:responses_url, "https://example.com/"},
      {:responses_url, "https://0x7f000001/v1/responses"},
      {:responses_url, "https://0x7f.0x0.0x0.0x1/v1/responses"},
      {:responses_url, "https://0x7f.1/v1/responses"},
      {:responses_url, "https://example.com:"},
      {:responses_url, "https://example.com:+80/v1/responses"},
      {:responses_url, "https://example.com:-1/v1/responses"},
      {:responses_url, "https://example.com:1e2/v1/responses"},
      {:responses_url, "https://example.com:http/v1/responses"},
      {:responses_url, "https://example.com:８０/v1/responses"},
      {:responses_url, "https://example.com:0/v1/responses"},
      {:responses_url, "https://vendor.example:00443/v1/responses"},
      {:responses_url, "https://example.com:65536/v1/responses"},
      {:responses_url, "https://example.com/%"},
      {:responses_url, "https://example.com/%0a"},
      {:responses_url, "https://example.com/a b"}
    ]

    for {kind, url} <- invalid do
      profile =
        %{"mode" => "open_responses", "auth" => %{"policy" => "none"}}
        |> Map.put(Atom.to_string(kind), url)

      assert_error(ResponsesBackend.resolve(profile), kind, :invalid_endpoint, url)
    end
  end

  test "every successful resolution is valid and idempotent" do
    cases = [
      {%{"mode" => "chatgpt_codex"}, :default},
      {%{"mode" => "chatgpt_codex"}, :config},
      {open_base("http://localhost:11434"), :config},
      {open_exact("https://vendor.example/v1/responses"), :provider_opts}
    ]

    for {profile, source} <- cases do
      assert {:ok, backend} = ResponsesBackend.resolve(profile, source: source)
      assert ResponsesBackend.valid?(backend)
      assert {:ok, ^backend} = ResponsesBackend.resolve(backend)
    end
  end

  test "open profiles cannot claim the implicit default source" do
    sentinel = "https://source-secret.example/v1/responses"

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :responses_backend, reason: :invalid_type}
              }
            } = error} =
             ResponsesBackend.resolve(open_exact(sentinel), source: :default)

    refute inspect(error) =~ sentinel
  end

  test "enforces endpoint length and DNS label boundaries" do
    prefix = "https://example.com/"
    url_2048 = prefix <> String.duplicate("a", 2048 - byte_size(prefix))
    url_2049 = url_2048 <> "a"

    assert {:ok, _} = ResponsesBackend.resolve(open_exact(url_2048))

    assert_error(
      ResponsesBackend.resolve(open_exact(url_2049)),
      :responses_url,
      :invalid_endpoint
    )

    label63 = String.duplicate("a", 63)
    label64 = String.duplicate("a", 64)
    assert {:ok, _} = ResponsesBackend.resolve(open_base("https://#{label63}.example"))

    assert_error(
      ResponsesBackend.resolve(open_base("https://#{label64}.example")),
      :base_url,
      :invalid_endpoint
    )
  end

  test "auth descriptors are closed and env names honor byte and grammar boundaries" do
    assert {:ok, none} = ResponsesBackend.resolve(open_base("http://localhost"))
    assert ResponsesBackend.auth_policy(none) == :none

    env128 = "A" <> String.duplicate("B", 127)
    assert {:ok, bearer} = ResponsesBackend.resolve(open_base("http://localhost", bearer(env128)))
    assert ResponsesBackend.auth_policy(bearer) == {:bearer_env, env128}

    for auth <- [
          %{"policy" => "bearer_env"},
          bearer(""),
          bearer("a_lower"),
          bearer("9INVALID"),
          bearer("A" <> String.duplicate("B", 128))
        ] do
      assert {:error, %{error: %{kind: :invalid_config}}} =
               ResponsesBackend.resolve(open_base("http://localhost", auth))
    end

    for auth <- [
          %{"policy" => "oauth"},
          %{"policy" => "none", "token" => "SECRET"},
          %{"policy" => "bearer_env", "env_var" => "TOKEN", "header" => "x"}
        ] do
      result = ResponsesBackend.resolve(open_base("http://localhost", auth))
      assert {:error, %{error: %{kind: :invalid_config}}} = result
      refute inspect(result) =~ "SECRET"
    end
  end

  test "rejects missing, conflicting, unknown, and normalized-collision fields" do
    assert_error(ResponsesBackend.resolve(nil), :responses_backend, :invalid_type)
    assert_error(ResponsesBackend.resolve(%{}), :mode, :missing_mode)
    assert_error(ResponsesBackend.resolve(%{"mode" => "future"}), :mode, :unknown_mode)

    assert_error(
      ResponsesBackend.resolve(%{"mode" => "chatgpt_codex", "other" => true}),
      :responses_backend,
      :unknown_field
    )

    assert_error(
      ResponsesBackend.resolve(%{
        "mode" => "open_responses",
        "base_url" => "http://localhost",
        "responses_url" => "http://localhost/v1/responses",
        "auth" => %{"policy" => "none"}
      }),
      :endpoint,
      :conflicting_endpoints
    )

    assert_error(
      ResponsesBackend.resolve(%{:mode => "chatgpt_codex", "mode" => "open_responses"}),
      :responses_backend,
      :unknown_field
    )
  end

  defp open_base(url, auth \\ %{"policy" => "none"}),
    do: %{"mode" => "open_responses", "base_url" => url, "auth" => auth}

  defp open_exact(url),
    do: %{"mode" => "open_responses", "responses_url" => url, "auth" => %{"policy" => "none"}}

  defp bearer(env_var), do: %{"policy" => "bearer_env", "env_var" => env_var}

  defp assert_error(result, field, reason, sentinel \\ nil) do
    assert {:error,
            %{
              ok: false,
              error: %{
                kind: :invalid_config,
                message: message,
                details: %{field: ^field, reason: ^reason} = details
              }
            }} = result

    assert is_binary(message) and message != ""
    assert map_size(details) == 2
    assert match?({:ok, _}, Jason.encode(elem(result, 1)))
    if is_binary(sentinel) and sentinel != "", do: refute(inspect(result) =~ sentinel)
  end
end
