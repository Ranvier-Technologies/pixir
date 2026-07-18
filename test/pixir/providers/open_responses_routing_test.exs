defmodule Pixir.Providers.OpenResponsesRoutingTest do
  use ExUnit.Case, async: false

  alias Pixir.Provider.ResponsesRouting
  alias Pixir.Providers.ResponsesBackend

  setup do
    previous = Application.get_env(:pixir, :provider_transport)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:pixir, :provider_transport),
        else: Application.put_env(:pixir, :provider_transport, previous)
    end)

    Application.delete_env(:pixir, :provider_transport)
    :ok
  end

  test "default backend preserves the ChatGPT URL and auto WebSocket policy" do
    backend = ResponsesBackend.default()
    assert {:ok, routing} = ResponsesRouting.resolve(backend)

    assert ResponsesRouting.http_url(routing) ==
             "https://chatgpt.com/backend-api/codex/responses"

    assert ResponsesRouting.websocket_url(routing) ==
             "wss://chatgpt.com/backend-api/codex/responses"

    assert ResponsesRouting.requested_transport(routing) == :auto
    assert ResponsesRouting.effective_transport(routing) == :auto
    assert ResponsesRouting.allowed_transports(routing) == [:websocket, :http_sse]
    assert ResponsesRouting.source(routing) == :default
    assert ResponsesRouting.validate_binding(routing, backend) == :ok
  end

  test "absent-profile legacy base_url keeps the current codex join rules" do
    backend = ResponsesBackend.default()

    cases = [
      {"https://legacy.invalid/backend-api",
       "https://legacy.invalid/backend-api/codex/responses"},
      {"https://legacy.invalid/backend-api/codex",
       "https://legacy.invalid/backend-api/codex/responses"},
      {"https://legacy.invalid/backend-api/codex/responses/",
       "https://legacy.invalid/backend-api/codex/responses"}
    ]

    for {base_url, expected} <- cases do
      assert {:ok, routing} = ResponsesRouting.resolve(backend, base_url: base_url)
      assert ResponsesRouting.http_url(routing) == expected

      assert ResponsesRouting.websocket_url(routing) ==
               String.replace_prefix(expected, "https", "wss")

      assert ResponsesRouting.source(routing) == :legacy_base_url
    end
  end

  test "ChatGPT accepts each existing transport policy without reinterpretation" do
    backend = ResponsesBackend.default()

    for requested <- [:auto, :websocket, :http_sse, "auto", "websocket", "http_sse"] do
      assert {:ok, routing} =
               ResponsesRouting.resolve(backend, provider_transport: requested)

      normalized =
        if is_binary(requested), do: String.to_existing_atom(requested), else: requested

      assert ResponsesRouting.requested_transport(routing) == normalized
      assert ResponsesRouting.effective_transport(routing) == normalized
    end
  end

  test "explicit profiles reject the raw legacy base_url option without leaking it" do
    sentinel = "https://ROUTING-SECRET.invalid"

    assert {:ok, chatgpt} =
             ResponsesBackend.resolve(%{"mode" => "chatgpt_codex"}, source: :provider_opts)

    open = open_backend(:base_url, "https://vendor.invalid")

    for backend <- [chatgpt, open] do
      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{field: :base_url, reason: :conflicting_legacy_option}
                }
              } = error} = ResponsesRouting.resolve(backend, base_url: sentinel)

      refute inspect(error) =~ sentinel
      assert {:ok, _json} = Jason.encode(error)
    end
  end

  test "open base_url appends exactly v1/responses and selects HTTP/SSE directly" do
    backend = open_backend(:base_url, "http://127.0.0.1:11434")
    assert {:ok, routing} = ResponsesRouting.resolve(backend)

    assert ResponsesRouting.http_url(routing) == "http://127.0.0.1:11434/v1/responses"
    assert ResponsesRouting.websocket_url(routing) == nil
    assert ResponsesRouting.requested_transport(routing) == :auto
    assert ResponsesRouting.effective_transport(routing) == :http_sse
    assert ResponsesRouting.allowed_transports(routing) == [:http_sse]
    assert ResponsesRouting.source(routing) == :base_url
  end

  test "open responses_url is preserved byte-for-byte" do
    endpoint = "https://vendor.invalid/custom/prefix/responses"
    backend = open_backend(:responses_url, endpoint)

    assert {:ok, routing} = ResponsesRouting.resolve(backend, provider_transport: :http_sse)
    assert ResponsesRouting.http_url(routing) === endpoint
    assert ResponsesRouting.requested_transport(routing) == :http_sse
    assert ResponsesRouting.effective_transport(routing) == :http_sse
    assert ResponsesRouting.source(routing) == :responses_url
  end

  test "open WebSocket request fails capability validation before seam compatibility" do
    backend = open_backend(:base_url, "https://vendor.invalid")
    sentinel_transport = fn _request, _acc, _fun -> flunk("transport must not run") end

    assert {:error,
            %{
              error: %{
                kind: :unsupported_transport,
                details: %{
                  requested_transport: :websocket,
                  allowed_transports: [:http_sse],
                  reason: :unsupported_transport
                }
              }
            }} =
             ResponsesRouting.resolve(backend,
               provider_transport: :websocket,
               transport: sentinel_transport
             )
  end

  test "injected legacy transport is an HTTP/SSE seam for allowed policies" do
    seam = fn _request, _acc, _fun -> flunk("resolution must not execute transport") end
    backend = ResponsesBackend.default()

    for requested <- [:auto, :http_sse] do
      assert {:ok, routing} =
               ResponsesRouting.resolve(backend,
                 provider_transport: requested,
                 transport: seam
               )

      assert ResponsesRouting.requested_transport(routing) == requested
      assert ResponsesRouting.effective_transport(routing) == :http_sse
    end

    assert {:error,
            %{
              error: %{
                kind: :invalid_args,
                details: %{field: :transport, reason: :incompatible_transport_seam}
              }
            }} =
             ResponsesRouting.resolve(backend,
               provider_transport: :websocket,
               transport: seam
             )

    assert {:error,
            %{
              error: %{
                kind: :invalid_args,
                details: %{field: :transport, reason: :invalid_transport_seam}
              }
            }} = ResponsesRouting.resolve(backend, transport: :not_a_transport_module)
  end

  test "explicit profiles reject invalid transports while default legacy falls back to auto" do
    assert {:ok, explicit} =
             ResponsesBackend.resolve(%{"mode" => "chatgpt_codex"}, source: :provider_opts)

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :provider_transport, reason: :invalid_transport}
              }
            }} = ResponsesRouting.resolve(explicit, provider_transport: :future)

    assert {:ok, legacy} =
             ResponsesRouting.resolve(ResponsesBackend.default(), provider_transport: :future)

    assert ResponsesRouting.requested_transport(legacy) == :auto
    assert ResponsesRouting.effective_transport(legacy) == :auto
  end

  test "application transport is read once by resolve and apply_to_opts freezes the result" do
    Application.put_env(:pixir, :provider_transport, :http_sse)
    assert {:ok, routing} = ResponsesRouting.resolve(ResponsesBackend.default())
    Application.put_env(:pixir, :provider_transport, :websocket)

    opts = ResponsesRouting.apply_to_opts(routing, session_id: "session")
    assert opts[:provider_transport] == :http_sse
    assert opts[:responses_routing] === routing
    assert opts[:session_id] == "session"
  end

  test "binding validation rejects a route from another backend with a safe error" do
    endpoint = "https://BINDING-SECRET.invalid/v1/responses"
    first = open_backend(:responses_url, endpoint)
    second = open_backend(:responses_url, "https://other.invalid/v1/responses")
    assert {:ok, routing} = ResponsesRouting.resolve(first)

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :responses_routing, reason: :backend_mismatch}
              }
            } = error} = ResponsesRouting.validate_binding(routing, second)

    refute inspect(error) =~ endpoint
    assert {:ok, _json} = Jason.encode(error)
  end

  test "summary and Inspect expose policy but no final endpoint or binding" do
    endpoint = "https://SUMMARY-SECRET.invalid/vendor/responses"
    backend = open_backend(:responses_url, endpoint)
    assert {:ok, routing} = ResponsesRouting.resolve(backend)

    summary = ResponsesRouting.summary(routing)

    assert summary == %{
             "requested_transport" => "auto",
             "effective_transport" => "http_sse",
             "allowed_transports" => ["http_sse"],
             "source" => "responses_url",
             "websocket_available" => false
           }

    assert {:ok, _json} = Jason.encode(summary)
    refute inspect(summary) =~ endpoint
    refute inspect(routing) =~ endpoint
    refute inspect(routing) =~ "backend_binding"
  end

  test "Inspect fails closed for fabricated routing values" do
    assert {:ok, routing} = ResponsesRouting.resolve(ResponsesBackend.default())
    sentinel = "FABRICATED-ROUTING-SECRET"

    for fabricated <- [
          struct(routing, url: sentinel),
          struct(routing, websocket_url: sentinel),
          struct(routing, requested_transport: sentinel),
          struct(routing, backend_binding: sentinel),
          struct(routing, source: :base_url)
        ] do
      assert ResponsesRouting.summary(fabricated) == :invalid
      assert inspect(fabricated) == "#ResponsesRouting<:invalid>"
      refute inspect(fabricated) =~ sentinel
    end
  end

  test "invalid inputs and invalid legacy endpoints fail closed" do
    sentinel = "https://URL-SECRET.invalid?token=sentinel"

    assert {:error, %{error: %{kind: :invalid_args}}} = ResponsesRouting.resolve(:invalid)

    assert {:error, %{error: %{kind: :invalid_args}}} =
             ResponsesRouting.resolve(ResponsesBackend.default(), [:not_keyword])

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :endpoint, reason: :invalid_endpoint}
              }
            } = error} = ResponsesRouting.resolve(ResponsesBackend.default(), base_url: sentinel)

    refute inspect(error) =~ sentinel
  end

  defp open_backend(kind, endpoint) do
    profile = %{
      "mode" => "open_responses",
      Atom.to_string(kind) => endpoint,
      "auth" => %{"policy" => "none"}
    }

    assert {:ok, backend} = ResponsesBackend.resolve(profile, source: :provider_opts)
    backend
  end
end
