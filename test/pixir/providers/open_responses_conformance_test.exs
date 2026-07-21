defmodule Pixir.Providers.OpenResponsesConformanceTest do
  use ExUnit.Case, async: false

  alias Pixir.{Event, Provider}
  alias Pixir.Provider.{OutputTruncation, ResponsesExtensions}
  alias Pixir.Providers.ResponsesBackend

  @fixture_dir Path.expand("../../fixtures/provider/open_responses", __DIR__)
  @fixture Path.join(@fixture_dir, "text_and_tool_call.sse")
  @error_fixture Path.join(@fixture_dir, "error_and_failed.sse")
  @request_fixture Path.join(@fixture_dir, "request.json")
  @manifest Path.join(@fixture_dir, "manifest.json")
  @schema_subset Path.join(@fixture_dir, "schema_subset.json")
  @schema_corpus Path.join(@fixture_dir, "schema_corpus.jsonl")
  @schema_corpus_bases Path.join(@fixture_dir, "schema_corpus_bases.json")
  @schema_manifest Path.join(@fixture_dir, "schema_manifest.json")

  defp open_profile(auth \\ %{"policy" => "none"}, route \\ "vendor.invalid") do
    %{
      "mode" => "open_responses",
      "responses_url" => "https://#{route}/v1/responses",
      "auth" => auth
    }
  end

  defp stream_transport(chunks, test \\ self()) do
    fn request, acc, fun ->
      send(test, {:open_request, request})
      acc = fun.({:status, 200}, acc)
      {:ok, Enum.reduce(chunks, acc, &fun.({:data, &1}, &2))}
    end
  end

  defp quiet_stream_transport(chunks) do
    fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, Enum.reduce(chunks, acc, &fun.({:data, &1}, &2))}
    end
  end

  defp chunks(binary, :one_byte), do: for(<<byte <- binary>>, do: <<byte>>)

  defp chunks(binary, boundaries) do
    Enum.reduce(boundaries, {binary, []}, fn size, {rest, acc} ->
      take = min(size, byte_size(rest))
      <<head::binary-size(^take), tail::binary>> = rest
      {tail, [head | acc]}
    end)
    |> then(fn {rest, acc} -> Enum.reverse([rest | acc]) end)
    |> Enum.reject(&(&1 == ""))
  end

  test "manifest pins fixture, request, upstream authority, roles, schemas, and probe digest" do
    manifest = Jason.decode!(File.read!(@manifest))

    assert digest(File.read!(@fixture)) == manifest["fixture"]["sha256"]
    assert digest(File.read!(@error_fixture)) == manifest["error_fixture"]["sha256"]
    assert digest(File.read!(@request_fixture)) == manifest["request"]["sha256"]
    assert manifest["fixture"]["event_count"] == 12
    assert manifest["error_fixture"]["event_count"] == 2
    assert manifest["mechanical_validation"]["total_event_count"] == 14
    assert manifest["mechanical_validation"]["result"] == "pass"

    structural = manifest["structural_validation"]
    schema_manifest = Jason.decode!(File.read!(@schema_manifest))
    assert structural["root_count"] == 24
    assert structural["reachable_schema_count"] == 69
    assert structural["response_resource_required_property_count"] == 31
    assert structural["corpus"]["row_count"] == schema_manifest["corpus"]["row_count"]
    assert structural["oracle_mismatches"] == 0
    assert digest(File.read!(@schema_subset)) == structural["subset"]["sha256"]
    assert digest(File.read!(@schema_corpus)) == structural["corpus"]["sha256"]
    assert digest(File.read!(@schema_corpus_bases)) == structural["corpus_bases"]["sha256"]
    assert digest(File.read!(@schema_manifest)) == structural["manifest"]["sha256"]

    assert manifest["mechanical_validation"]["message_roles"] ==
             ~w(assistant developer system user)

    assert manifest["upstream"]["commit"] ==
             "cd31bc2060a27ee87a05ec97f49c84027eb6c3ba"

    assert "#/components/schemas/CreateResponseBody" in manifest["request"]["schema_pointers"]

    for role <- ~w(User Developer System Assistant) do
      assert "#/components/schemas/#{role}MessageItemParam" in manifest["request"][
               "schema_pointers"
             ]
    end

    assert "#/components/schemas/FunctionToolParam" in manifest["request"]["schema_pointers"]

    assert "#/components/schemas/ResponseCompletedStreamingEvent" in manifest["fixture"][
             "schema_pointers"
           ]

    assert "#/components/schemas/ErrorStreamingEvent" in manifest["error_fixture"][
             "schema_pointers"
           ]

    assert "#/components/schemas/ErrorPayload" in manifest["error_fixture"]["schema_pointers"]

    assert "#/components/schemas/ResponseFailedStreamingEvent" in manifest["error_fixture"][
             "schema_pointers"
           ]

    assert manifest["probe"]["combined_sha256"] ==
             Mix.Tasks.Pixir.Smoke.OpenResponses.probe_digest()

    assert manifest["probe"]["version"] == Mix.Tasks.Pixir.Smoke.OpenResponses.probe_version()
  end

  test "strict runtime validator accepts every pinned fixture event before activation" do
    assert {:ok, decoder, frames} =
             Pixir.Provider.SSEDecoder.feed(
               Pixir.Provider.SSEDecoder.new(),
               File.read!(@fixture)
             )

    assert {:ok, _decoder, tail, _summary} = Pixir.Provider.SSEDecoder.finish(decoder)

    events =
      (frames ++ tail)
      |> Enum.reject(&(&1 == :done))
      |> Enum.map(&Jason.decode!(&1.data))

    assert length(events) == 12
    assert Enum.all?(events, &(ResponsesExtensions.validate_stream_event(&1) == {:ok, :known}))

    assert {:ok, error_decoder, error_frames} =
             Pixir.Provider.SSEDecoder.feed(
               Pixir.Provider.SSEDecoder.new(),
               File.read!(@error_fixture)
             )

    assert {:ok, _error_decoder, error_tail, _summary} =
             Pixir.Provider.SSEDecoder.finish(error_decoder)

    error_events =
      (error_frames ++ error_tail)
      |> Enum.reject(&(&1 == :done))
      |> Enum.map(&Jason.decode!(&1.data))

    assert length(error_events) == 2

    assert Enum.all?(
             error_events,
             &(ResponsesExtensions.validate_stream_event(&1) == {:ok, :known})
           )
  end

  test "every oracle-invalid corpus row fails through the public Provider" do
    invalid_rows = Enum.filter(corpus_rows(), &(&1["disposition"] == "invalid"))
    schema_manifest = Jason.decode!(File.read!(@schema_manifest))
    assert length(invalid_rows) == schema_manifest["corpus"]["counts"]["invalid"]

    successes =
      Enum.flat_map(invalid_rows, fn row ->
        event_name = if is_map(row["event"]), do: row["event"]["type"], else: row["base"]
        stream = strict_sse(event_name, row["event"])

        case Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: quiet_stream_transport([stream]),
               max_retries: 0
             ) do
          {:error, _error} -> []
          {:ok, _result} -> [row["label"]]
        end
      end)

    assert successes == []
  end

  test "nested runtime schema rejects terminal nulls floats roles usage gaps and error key gaps" do
    valid_message = %{
      "type" => "message",
      "id" => "msg_nested",
      "status" => "completed",
      "role" => "assistant",
      "content" => []
    }

    valid_refusal = %{
      valid_message
      | "content" => [%{"type" => "refusal", "refusal" => "cannot comply"}]
    }

    assert ResponsesExtensions.validate_stream_event(
             error_event(%{
               "type" => "server_error",
               "code" => nil,
               "message" => "safe",
               "param" => nil
             })
           ) == {:ok, :known}

    assert ResponsesExtensions.validate_stream_event(
             response_event("response.failed", %{
               "status" => "failed",
               "error" => %{"code" => "server_error", "message" => "safe"}
             })
           ) == {:ok, :known}

    assert ResponsesExtensions.validate_stream_event(
             response_event("response.failed", %{"status" => "failed", "error" => nil})
           ) == {:ok, :known}

    assert ResponsesExtensions.validate_stream_event(
             terminal_event(%{"output" => [valid_refusal]})
           ) == {:unsupported, :nonportable_content}

    invalid_events = [
      {:terminal_null_item, terminal_event(%{"output" => [nil]})},
      {:float_created_at, terminal_event(%{"created_at" => 1.5})},
      {:float_completed_at, terminal_event(%{"completed_at" => 2.5})},
      {:invalid_message_role,
       terminal_event(%{"output" => [%{valid_message | "role" => "critic"}]})},
      {:empty_usage, terminal_event(%{"usage" => %{}})},
      {:missing_input_details,
       terminal_event(%{
         "usage" =>
           valid_usage()
           |> Map.delete("input_tokens_details")
       })},
      {:missing_output_details,
       terminal_event(%{
         "usage" =>
           valid_usage()
           |> Map.delete("output_tokens_details")
       })},
      {:missing_cached_tokens,
       terminal_event(%{
         "usage" => put_in(valid_usage(), ["input_tokens_details"], %{})
       })},
      {:missing_reasoning_tokens,
       terminal_event(%{
         "usage" => put_in(valid_usage(), ["output_tokens_details"], %{})
       })},
      {:instructions_list, terminal_event(%{"instructions" => []})},
      {:empty_response_error, terminal_event(%{"error" => %{}})},
      {:missing_refusal,
       terminal_event(%{
         "output" => [%{valid_message | "content" => [%{"type" => "refusal"}]}]
       })},
      {:wrong_refusal_scalar,
       terminal_event(%{
         "output" => [
           %{valid_message | "content" => [%{"type" => "refusal", "refusal" => 7}]}
         ]
       })},
      {:missing_error_code,
       error_event(%{"type" => "server_error", "message" => "safe", "param" => nil})},
      {:missing_error_param,
       error_event(%{"type" => "server_error", "code" => nil, "message" => "safe"})}
    ]

    for {name, event} <- invalid_events do
      assert ResponsesExtensions.validate_stream_event(event) ==
               {:error, :invalid_event_shape},
             inspect(name)
    end

    for event_type <-
          ~w(response.created response.in_progress response.incomplete response.failed),
        invalid_error <- [%{}, [], "wrong", 7] do
      event =
        response_event(event_type, %{
          "status" => response_status(event_type),
          "error" => invalid_error
        })

      assert ResponsesExtensions.validate_stream_event(event) ==
               {:error, :invalid_event_shape},
             inspect({event_type, invalid_error})
    end

    for type <- ["response.output_item.added", "response.output_item.done"] do
      assert ResponsesExtensions.validate_stream_event(%{
               "type" => type,
               "sequence_number" => 1,
               "output_index" => 0,
               "item" => nil
             }) == {:ok, :known}
    end
  end

  test "request fixture selected fields preserve strict portable shape" do
    body = Jason.decode!(File.read!(@request_fixture))
    assert body["store"] == false
    assert body["stream"] == true
    assert body["tool_choice"] == "auto"
    assert body["parallel_tool_calls"] == true
    assert Enum.map(body["input"], & &1["role"]) == ~w(developer system user assistant)
    assert Enum.all?(body["input"], &(&1["type"] == "message"))

    assert [%{"type" => "function", "name" => "pixir_open_responses_probe"}] =
             Enum.map(body["tools"], &Map.take(&1, ["type", "name"]))
  end

  test "all four extension ids are capability-gated for both backend modes" do
    default = ResponsesBackend.default()
    {:ok, open} = ResponsesBackend.resolve(open_profile(), source: :provider_opts)

    expected_default = %{
      prompt_cache_key: true,
      prompt_cache_retention: false,
      reasoning_encrypted_content: true,
      hosted_tool_includes: true
    }

    Enum.each(expected_default, fn {extension, allowed?} ->
      assert ResponsesExtensions.allowed?(default, extension) == allowed?
      refute ResponsesExtensions.allowed?(open, extension)
    end)

    assert ResponsesExtensions.headers(default) == [
             {"content-type", "application/json"},
             {"accept", "text/event-stream"},
             {"openai-beta", "responses=experimental"},
             {"originator", "pixir"}
           ]

    assert ResponsesExtensions.headers(open) == [
             {"content-type", "application/json"},
             {"accept", "text/event-stream"}
           ]
  end

  test "strict projection types every message role, drops reasoning, and preserves other items" do
    {:ok, open} = ResponsesBackend.resolve(open_profile(), source: :provider_opts)

    items = [
      %{"role" => "user", "content" => "u"},
      %{"role" => "developer", "content" => "d"},
      %{"role" => "system", "content" => "s"},
      %{"role" => "assistant", "content" => "a"},
      %{"type" => "reasoning", "encrypted_content" => "must-not-cross"},
      %{"type" => "function_call", "call_id" => "c", "name" => "f", "arguments" => "{}"},
      %{"type" => "future:item", "value" => 1}
    ]

    assert projected = ResponsesExtensions.project_input(open, items)

    assert Enum.take(projected, 4) ==
             Enum.map(Enum.take(items, 4), &Map.put(&1, "type", "message"))

    refute Enum.any?(projected, &(&1["type"] == "reasoning"))
    assert Enum.at(projected, 4) == Enum.at(items, 5)
    assert Enum.at(projected, 5) == Enum.at(items, 6)
    assert ResponsesExtensions.project_input(ResponsesBackend.default(), items) == items
  end

  test "pinned LF CRLF and CR fixtures traverse public Provider at one-byte boundaries" do
    fixture = File.read!(@fixture)

    for {line_ending, encoded} <- [
          {:lf, fixture},
          {:crlf, String.replace(fixture, "\n", "\r\n")},
          {:cr, String.replace(fixture, "\n", "\r")}
        ] do
      assert {:ok, result} =
               Provider.stream(fixture_request(),
                 responses_backend: open_profile(),
                 provider_transport: :auto,
                 auth: :must_not_be_called,
                 env_reader: fn _ -> flunk("credential reader must not run for auth none") end,
                 transport: stream_transport(chunks(encoded, :one_byte)),
                 max_retries: 0
               )

      assert result.text == "fixture text", inspect(line_ending)
      assert result.finish_reason == :tool_calls

      assert [call] = result.function_calls

      assert call == %{
               call_id: "call_fixture",
               name: "pixir_open_responses_probe",
               args: %{"probe" => "ok"}
             }

      assert result.usage_summary.input_tokens == 7
      assert result.usage_summary.output_tokens == 5
      assert result.usage_summary.total_tokens == 12
      assert OutputTruncation.status(result.output_truncation) == :not_truncated
      assert OutputTruncation.provider_reason(result.output_truncation) == "response.completed"
      assert result.provider_metadata["open_responses"]["done"] == true
      assert result.provider_metadata["open_responses"]["event_type_match"] == true
      assert result.reasoning_items == []
      assert result.provider_hosted_tools == %{}

      assert_received {:open_request, request}
      assert request.url == "https://vendor.invalid/v1/responses"

      assert request.headers == [
               {"content-type", "application/json"},
               {"accept", "text/event-stream"}
             ]

      body = Jason.decode!(request.body)
      assert body["store"] == false
      assert body["stream"] == true
      assert Enum.all?(body["input"], fn item -> item["type"] == "message" end)

      for key <- [
            "include",
            "prompt_cache_key",
            "prompt_cache_retention",
            "reasoning"
          ] do
        refute Map.has_key?(body, key)
      end

      assert Enum.all?(body["tools"], &(&1["type"] == "function"))
    end
  end

  test "table chunk boundaries preserve the pinned fixture" do
    fixture = File.read!(@fixture)

    for boundaries <- [[1, 2, 3, 5, 8, 13], [7, 31, 127, 1024], [4095, 2, 1]] do
      assert {:ok, result} =
               Provider.stream(fixture_request(),
                 responses_backend: open_profile(),
                 transport: stream_transport(chunks(fixture, boundaries)),
                 max_retries: 0
               )

      assert result.text == "fixture text"
      assert length(result.function_calls) == 1
      assert OutputTruncation.status(result.output_truncation) == :not_truncated
    end
  end

  test "two routes cannot alter empty extensions or portable headers" do
    for route <- ["one.invalid", "two.invalid"] do
      assert {:ok, _result} =
               Provider.stream(%{history: [Event.user_message("s", "hi")]},
                 responses_backend: open_profile(%{"policy" => "none"}, route),
                 transport: stream_transport([completed_stream()]),
                 max_retries: 0
               )

      assert_received {:open_request, request}
      body = Jason.decode!(request.body)

      assert request.headers == [
               {"content-type", "application/json"},
               {"accept", "text/event-stream"}
             ]

      refute Map.has_key?(body, "include")
      refute Map.has_key?(body, "prompt_cache_key")
    end
  end

  test "requested reasoning and hosted tools fail before route Auth or transport" do
    bearer = %{"policy" => "bearer_env", "env_var" => "VENDOR_TOKEN"}
    profile = open_profile(bearer)

    cases = [
      {%{history: [], reasoning_effort: "low"}, :reasoning},
      {%{history: [], web_search: true}, :provider_hosted_tools},
      {%{history: [], hosted_tools: [%{"type" => "web_search"}]}, :provider_hosted_tools}
    ]

    for {request, capability} <- cases do
      assert {:error,
              %{
                error: %{
                  kind: :unsupported_backend_capability,
                  details: %{capability: ^capability}
                }
              }} =
               Provider.stream(request,
                 responses_backend: profile,
                 env_reader: fn _ -> flunk("credential must not be released") end,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end,
                 max_retries: 0
               )
    end
  end

  test "explicit nonnil invalid reasoning fails before routing body Auth or transport" do
    profile = open_profile(%{"policy" => "bearer_env", "env_var" => "VENDOR_TOKEN"})

    request = %{history: :body_must_not_be_built, reasoning_effort: "turbo"}

    opts = [
      responses_backend: profile,
      provider_transport: :future,
      env_reader: fn _ -> flunk("credential must not be released") end,
      transport: fn _request, _acc, _fun -> flunk("transport must not run") end,
      max_retries: 0
    ]

    for invocation <- [
          fn -> Provider.stream(request, opts) end,
          fn -> Provider.request_body_preview(request, opts) end
        ] do
      assert {:error,
              %{
                error: %{
                  kind: :unsupported_backend_capability,
                  details: %{capability: :reasoning}
                }
              }} = invocation.()
    end
  end

  test "stored reasoning is dropped and streamed reasoning fails before delta or tool use" do
    history = [
      Event.user_message("s", "hi"),
      Event.reasoning(
        "s",
        %{"type" => "reasoning", "encrypted_content" => "ciphertext"},
        "fixture-model"
      )
    ]

    assert {:ok, _result} =
             Provider.stream(%{model: "fixture-model", history: history},
               responses_backend: open_profile(),
               transport: stream_transport([completed_stream()]),
               max_retries: 0
             )

    assert_received {:open_request, request}
    refute Enum.any?(Jason.decode!(request.body)["input"], &(&1["type"] == "reasoning"))
    parent = self()

    reasoning_stream =
      strict_sse("response.reasoning.delta", %{
        "type" => "response.reasoning.delta",
        "sequence_number" => 1,
        "item_id" => "reasoning-item",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => "secret"
      }) <>
        strict_sse("response.output_item.done", %{
          "type" => "response.output_item.done",
          "sequence_number" => 2,
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_x",
            "call_id" => "call_x",
            "name" => "danger",
            "arguments" => "{}",
            "status" => "completed"
          }
        })

    assert {:error, %{error: %{kind: :unsupported_backend_capability}}} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               on_delta: fn delta -> send(parent, {:unexpected_delta, delta}) end,
               transport: stream_transport([reasoning_stream]),
               max_retries: 0
             )

    refute_received {:unexpected_delta, _delta}
  end

  test "strict event mismatch malformed JSON post-DONE and invalid UTF-8 fail boundedly" do
    invalid_streams = [
      "event: response.completed\ndata: {\"type\":\"response.incomplete\"}\n\n",
      "event: response.completed\ndata: {broken}\n\n",
      "data: [DONE]\n\ndata: {}\n\n",
      "event: response.completed\ndata: " <> <<0xFF>> <> "\n\n"
    ]

    Enum.each(invalid_streams, fn stream ->
      assert {:error, %{error: %{kind: :invalid_response, details: details}} = error} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream]),
                 max_retries: 0
               )

      assert is_atom(details.reason)
      refute inspect(error) =~ "broken"
      refute inspect(error) =~ <<0xFF>>
    end)
  end

  test "parseable non-string event type is an invalid shape rather than malformed JSON" do
    stream = "event: response.completed\ndata: {\"type\":1}\n\n"

    assert {:error,
            %{
              error: %{
                kind: :invalid_response,
                details: %{reason: :invalid_event_shape}
              }
            }} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )
  end

  test "later framing failure retains safe already-observed terminal audit" do
    stream = completed_stream() <> "data: [DONE]\n\ndata: again\n\n"

    assert {:error,
            %{
              error: %{
                kind: :invalid_response,
                details: %{
                  reason: :event_after_done,
                  terminal_event_type: "response.completed",
                  terminal_summary: terminal
                }
              }
            }} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    assert terminal.status == :not_truncated
  end

  test "open in-band errors are fixed bounded projections without remote sentinels" do
    sentinel = String.duplicate("REMOTE-SENTINEL-", 1_280)

    remote_error = %{
      "type" => "server_error_" <> sentinel,
      "code" => "vendor_code_" <> sentinel,
      "message" => sentinel,
      "param" => "vendor_param_" <> sentinel
    }

    streams = [
      strict_sse("error", %{
        "type" => "error",
        "sequence_number" => 1,
        "error" => remote_error
      }),
      strict_sse("response.failed", %{
        "type" => "response.failed",
        "sequence_number" => 1,
        "response" => response_resource(%{"status" => "failed", "error" => remote_error})
      })
    ]

    for stream <- streams do
      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  message: "The Open Responses stream reported a Provider failure.",
                  details: details
                }
              } = error} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream <> "data: [DONE]\n\n"]),
                 max_retries: 0
               )

      assert details.remote_error_class == :provider_failure
      assert details.remote_message_bytes == byte_size(sentinel)
      assert byte_size(inspect(error)) < 2_048
      refute inspect(error) =~ sentinel
      refute inspect(error) =~ "vendor_code_"
      refute inspect(error) =~ "vendor_param_"
    end
  end

  test "response failed uses distinct bounded response error while invalid completed fields fail" do
    for {response_error, field_count} <- [
          {%{"code" => "server_error", "message" => "remote failure"}, 2},
          {nil, 0}
        ] do
      stream =
        strict_sse("response.failed", %{
          "type" => "response.failed",
          "sequence_number" => 1,
          "response" =>
            response_resource(%{
              "status" => "failed",
              "error" => response_error
            })
        }) <> "data: [DONE]\n\n"

      assert {:error,
              %{
                error: %{
                  kind: :provider_http_error,
                  message: "The Open Responses stream reported a Provider failure.",
                  details: %{event_type: "response.failed", remote_field_count: ^field_count}
                }
              } = projected} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream]),
                 max_retries: 0
               )

      refute inspect(projected) =~ "remote failure"
    end

    for overrides <- [%{"instructions" => []}, %{"error" => %{}}] do
      invalid =
        strict_sse("response.completed", %{
          "type" => "response.completed",
          "sequence_number" => 1,
          "response" => response_resource(overrides)
        })

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{reason: :invalid_event_shape}
                }
              }} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([invalid]),
                 max_retries: 0
               )
    end
  end

  test "a semantic frame after completed is invalid and exposes no later function call" do
    call_name = "must_not_be_exposed"

    stream =
      completed_event() <>
        strict_sse("response.output_item.done", %{
          "type" => "response.output_item.done",
          "sequence_number" => 2,
          "output_index" => 0,
          "item" => %{
            "type" => "function_call",
            "id" => "fc_late",
            "call_id" => "call_late",
            "name" => call_name,
            "arguments" => "{}",
            "status" => "completed"
          }
        }) <>
        "data: [DONE]\n\n"

    assert {:error,
            %{
              error: %{
                kind: :invalid_response,
                details: %{
                  reason: :semantic_event_after_terminal,
                  terminal_event_type: "response.completed",
                  terminal_summary: %{status: :not_truncated}
                }
              }
            } = error} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    refute inspect(error) =~ call_name
    refute inspect(error) =~ "call_late"
  end

  test "unknown output item families are malformed known events, never hosted capabilities" do
    for item_type <- ["file_search_call", "vendor_future_tool_call"] do
      stream =
        strict_sse("response.output_item.done", %{
          "type" => "response.output_item.done",
          "sequence_number" => 1,
          "output_index" => 0,
          "item" => %{"type" => item_type, "opaque" => String.duplicate("x", 20_000)}
        })

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{reason: :invalid_event_shape}
                }
              } = error} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream]),
                 max_retries: 0
               )

      refute inspect(error) =~ item_type
      assert byte_size(inspect(error)) < 1_024
    end
  end

  test "schema-valid unsupported families have singular fixed capability dispositions" do
    cases = [
      {:nonportable_output_item,
       %{
         "type" => "response.output_item.done",
         "sequence_number" => 1,
         "output_index" => 0,
         "item" => %{
           "type" => "function_call_output",
           "id" => "output-item",
           "call_id" => "call-id",
           "output" => "bounded",
           "status" => "completed"
         }
       }},
      {:nonportable_content,
       %{
         "type" => "response.refusal.delta",
         "sequence_number" => 1,
         "item_id" => "message-item",
         "output_index" => 0,
         "content_index" => 0,
         "delta" => "bounded"
       }},
      {:reasoning,
       %{
         "type" => "response.reasoning.delta",
         "sequence_number" => 1,
         "item_id" => "reasoning-item",
         "output_index" => 0,
         "content_index" => 0,
         "delta" => "bounded"
       }}
    ]

    for {capability, event} <- cases do
      stream = strict_sse(event["type"], event)

      assert {:error,
              %{
                error: %{
                  kind: :unsupported_backend_capability,
                  details: %{capability: ^capability}
                }
              }} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream]),
                 max_retries: 0
               )
    end
  end

  test "open annotations and logprobs validate but do not create hosted-tool evidence" do
    citation = %{
      "type" => "url_citation",
      "url" => "https://citation.invalid",
      "start_index" => 0,
      "end_index" => 4,
      "title" => "citation"
    }

    message = %{
      "type" => "message",
      "id" => "message-item",
      "status" => "completed",
      "role" => "assistant",
      "content" => [
        %{
          "type" => "output_text",
          "text" => "text",
          "annotations" => [citation],
          "logprobs" => [
            %{"token" => "t", "logprob" => 0, "bytes" => [], "top_logprobs" => []}
          ]
        }
      ]
    }

    stream =
      strict_sse("response.output_item.done", %{
        "type" => "response.output_item.done",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => message
      }) <> completed_stream()

    assert {:ok, result} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    assert result.provider_hosted_tools == %{}
    refute inspect(result.provider_metadata) =~ "citation.invalid"
  end

  test "known active events require their pinned runtime shape before reduction" do
    malformed = [
      {"error", %{"type" => "error", "error" => %{}}},
      {"response.created", %{"type" => "response.created", "sequence_number" => 1}},
      {"response.in_progress", %{"type" => "response.in_progress", "sequence_number" => 1}},
      {"response.output_item.added",
       %{"type" => "response.output_item.added", "sequence_number" => 1, "item" => nil}},
      {"response.output_item.done",
       %{
         "type" => "response.output_item.done",
         "sequence_number" => 1,
         "output_index" => 0,
         "item" => %{"type" => "function_call"}
       }},
      {"response.content_part.added",
       %{
         "type" => "response.content_part.added",
         "sequence_number" => 1,
         "item_id" => "m",
         "output_index" => 0,
         "content_index" => 0
       }},
      {"response.content_part.done",
       %{
         "type" => "response.content_part.done",
         "sequence_number" => 1,
         "item_id" => "m",
         "output_index" => 0,
         "part" => %{"type" => "text", "text" => "x"}
       }},
      {"response.output_text.delta",
       %{
         "type" => "response.output_text.delta",
         "sequence_number" => 1,
         "output_index" => 0,
         "content_index" => 0,
         "delta" => "x"
       }},
      {"response.output_text.done",
       %{
         "type" => "response.output_text.done",
         "sequence_number" => 1,
         "item_id" => "m",
         "output_index" => 0,
         "content_index" => 0
       }},
      {"response.function_call_arguments.delta",
       %{
         "type" => "response.function_call_arguments.delta",
         "sequence_number" => 1,
         "item_id" => "fc",
         "output_index" => 0
       }},
      {"response.function_call_arguments.done",
       %{
         "type" => "response.function_call_arguments.done",
         "sequence_number" => 1,
         "item_id" => "fc",
         "output_index" => 0
       }},
      {"response.completed",
       %{"type" => "response.completed", "sequence_number" => 1, "response" => %{}}},
      {"response.incomplete", %{"type" => "response.incomplete", "sequence_number" => 1}},
      {"response.failed", %{"type" => "response.failed", "sequence_number" => 1}}
    ]

    for {event_type, body} <- malformed do
      stream = strict_sse(event_type, body)

      assert {:error,
              %{
                error: %{
                  kind: :invalid_response,
                  details: %{reason: :invalid_event_shape, event_type: ^event_type}
                }
              }} =
               Provider.stream(%{history: []},
                 responses_backend: open_profile(),
                 transport: stream_transport([stream]),
                 max_retries: 0
               )
    end
  end

  test "terminal conflict retains the first safe terminal audit" do
    stream =
      completed_event() <>
        strict_sse("response.incomplete", %{
          "type" => "response.incomplete",
          "sequence_number" => 2,
          "response" =>
            response_resource(%{
              "status" => "incomplete",
              "incomplete_details" => %{"reason" => "max_output_tokens"}
            })
        })

    assert {:error,
            %{
              error: %{
                kind: :invalid_response,
                details: %{
                  field: :terminal_lifecycle,
                  terminal_event_type: "response.completed",
                  terminal_summary: terminal
                }
              }
            }} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    assert terminal.status == :not_truncated
    assert terminal.provider_reason == "response.completed"
  end

  test "unknown matched events are bounded as other and EOF pending data is discarded" do
    stream =
      strict_sse("vendor:future", %{"type" => "vendor:future", "opaque" => "ignored"}) <>
        String.replace_suffix(completed_stream(), "data: [DONE]\n\n", "") <>
        "event: response.output_text.delta\ndata: pending"

    assert {:ok, result} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    assert result.provider_metadata["open_responses"]["known_event_counts"]["other"] == 1
    assert result.provider_metadata["open_responses_decoder"]["discarded_pending"] == true
    assert OutputTruncation.status(result.output_truncation) == :not_truncated
  end

  test "unknown pre-terminal events are opaque and cannot reach the default reducer" do
    sentinel = "remote-sentinel-" <> String.duplicate("x", 20_000)
    long_type = "vendor." <> String.duplicate("future", 2_000)

    unknown_events = [
      {"response.web_search_call.completed",
       %{
         "type" => "response.web_search_call.completed",
         "output_index" => 0,
         "item" => %{
           "type" => "web_search_call",
           "id" => sentinel,
           "status" => "completed",
           "action" => %{"type" => "search", "query" => sentinel}
         }
       }},
      {long_type,
       %{
         "type" => long_type,
         "item" => %{"type" => "function_call", "name" => sentinel},
         "output" => sentinel
       }}
    ]

    stream =
      Enum.map_join(unknown_events, fn {type, event} -> strict_sse(type, event) end) <>
        completed_stream()

    assert {:ok, result} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    assert result.provider_metadata["open_responses"]["known_event_counts"]["other"] == 2
    assert result.provider_hosted_tools == %{}
    assert result.function_calls == []
    refute inspect(result) =~ sentinel
    refute inspect(result) =~ long_type
  end

  test "unknown post-terminal diagnostics omit arbitrary remote type and values" do
    sentinel = "remote-sentinel-" <> String.duplicate("x", 20_000)
    unknown_type = "response.web_search_call." <> String.duplicate("future", 2_000)

    stream =
      completed_event() <>
        strict_sse(unknown_type, %{
          "type" => unknown_type,
          "item" => %{"type" => "web_search_call", "id" => sentinel},
          "opaque" => sentinel
        })

    assert {:error,
            %{
              error: %{
                kind: :invalid_response,
                details: %{reason: :semantic_event_after_terminal} = details
              }
            } = error} =
             Provider.stream(%{history: []},
               responses_backend: open_profile(),
               transport: stream_transport([stream]),
               max_retries: 0
             )

    refute Map.has_key?(details, :event_type)
    refute inspect(error) =~ unknown_type
    refute inspect(error) =~ sentinel
    assert byte_size(inspect(error)) < 2_048
  end

  defp fixture_request do
    %{
      model: "fixture-model",
      system_prompt: "fixture instructions",
      developer_context: "developer fixture",
      history: [Event.user_message("fixture", "user fixture")],
      tools: [
        %{
          "type" => "function",
          "name" => "pixir_open_responses_probe",
          "description" => "fixture",
          "parameters" => %{"type" => "object"}
        }
      ],
      prompt_cache_key: "must-be-omitted",
      prompt_cache_retention: "24h"
    }
  end

  defp completed_stream do
    completed_event() <> "data: [DONE]\n\n"
  end

  defp completed_event do
    strict_sse("response.completed", %{
      "type" => "response.completed",
      "sequence_number" => 1,
      "response" => response_resource()
    })
  end

  defp response_resource(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "resp_test",
        "object" => "response",
        "created_at" => 1,
        "completed_at" => 2,
        "status" => "completed",
        "incomplete_details" => nil,
        "model" => "fixture-model",
        "previous_response_id" => nil,
        "instructions" => "fixture instructions",
        "output" => [],
        "error" => nil,
        "tools" => [],
        "tool_choice" => "auto",
        "truncation" => "disabled",
        "parallel_tool_calls" => true,
        "text" => %{"format" => %{"type" => "text"}},
        "top_p" => 1,
        "presence_penalty" => 0,
        "frequency_penalty" => 0,
        "top_logprobs" => 0,
        "temperature" => 1,
        "reasoning" => nil,
        "usage" => valid_usage(),
        "max_output_tokens" => nil,
        "max_tool_calls" => nil,
        "store" => false,
        "background" => false,
        "service_tier" => "default",
        "metadata" => %{},
        "safety_identifier" => nil,
        "prompt_cache_key" => nil
      },
      overrides
    )
  end

  defp terminal_event(response_overrides) do
    response_event("response.completed", response_overrides)
  end

  defp response_event(type, response_overrides) do
    %{
      "type" => type,
      "sequence_number" => 1,
      "response" => response_resource(response_overrides)
    }
  end

  defp response_status("response.failed"), do: "failed"
  defp response_status("response.incomplete"), do: "incomplete"
  defp response_status("response.created"), do: "queued"
  defp response_status("response.in_progress"), do: "in_progress"

  defp error_event(error) do
    %{"type" => "error", "sequence_number" => 1, "error" => error}
  end

  defp valid_usage do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end

  defp strict_sse(event, body), do: "event: #{event}\ndata: #{Jason.encode!(body)}\n\n"

  defp corpus_rows do
    bases = @schema_corpus_bases |> File.read!() |> Jason.decode!()

    @schema_corpus
    |> File.stream!(:line, [])
    |> Enum.map(fn line ->
      row = Jason.decode!(line)
      Map.put(row, "event", expand_recipe!(Map.fetch!(bases, row["base"]), row["ops"]))
    end)
  end

  defp expand_recipe!(base, operations) do
    Enum.reduce(operations, base, fn
      %{"op" => "replace-root", "value" => value}, _event -> value
      %{"op" => "set", "path" => path, "value" => value}, event -> put_path!(event, path, value)
      %{"op" => "delete", "path" => path}, event -> delete_path!(event, path)
    end)
  end

  defp put_path!(_value, [], replacement), do: replacement
  defp put_path!(map, [key], value) when is_map(map), do: Map.put(map, key, value)

  defp put_path!(map, [key | rest], value) when is_map(map),
    do: Map.put(map, key, put_path!(Map.fetch!(map, key), rest, value))

  defp delete_path!(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp delete_path!(map, [key | rest]) when is_map(map),
    do: Map.put(map, key, delete_path!(Map.fetch!(map, key), rest))

  defp digest(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
