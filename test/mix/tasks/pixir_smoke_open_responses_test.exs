defmodule Mix.Tasks.Pixir.Smoke.OpenResponsesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pixir.Smoke.OpenResponses, as: Smoke
  alias Pixir.Provider
  alias Pixir.Provider.OutputTruncation

  @schema_corpus Path.expand(
                   "../../fixtures/provider/open_responses/schema_corpus.jsonl",
                   __DIR__
                 )
  @schema_corpus_bases Path.expand(
                         "../../fixtures/provider/open_responses/schema_corpus_bases.json",
                         __DIR__
                       )

  test "help JSON is bounded and does not inspect configured profile" do
    with_config("not-json", fn _home ->
      payload =
        capture_io(fn -> assert Smoke.run(["--json", "--help"]) == :ok end)
        |> Jason.decode!()

      assert payload["ok"] == true
      assert payload["planned_calls"] == 2
      assert payload["probe_digest"] == Smoke.probe_digest()

      assert payload["options"] == [
               "--model MODEL",
               "--timeout-ms N",
               "--output DIR",
               "--dry-run",
               "--json",
               "--help"
             ]
    end)
  end

  test "dry-run validates canonical open profile without credential reads network or writes" do
    endpoint = "https://secret-vendor.invalid/v1/responses"
    model = "secret-model"
    profile = open_profile(endpoint, %{"policy" => "bearer_env", "env_var" => "MISSING_TOKEN"})

    with_config(Jason.encode!(%{"responses_backend" => profile}), fn home ->
      output = Path.join(home, "must-not-exist")

      payload =
        capture_io(fn ->
          assert Smoke.run([
                   "--dry-run",
                   "--json",
                   "--model",
                   model,
                   "--output",
                   output
                 ]) == :ok
        end)
        |> Jason.decode!()

      assert payload["ok"] == true
      assert payload["mode"] == "dry_run"
      assert payload["network"] == false
      assert payload["writes"] == false
      assert payload["planned_calls"] == 2
      assert payload["request_shape"]["store"] == false
      assert payload["request_shape"]["stream"] == true
      assert payload["request_shape"]["message_discriminators"] == true
      assert payload["request_shape"]["include_present"] == false
      assert payload["request_shape"]["reasoning_present"] == false
      assert payload["request_shape"]["hosted_tool_present"] == false
      assert payload["routing"]["effective_transport"] == "http_sse"
      assert payload["extensions_applied"] == []
      assert "authorization" in payload["safe_header_names"]
      refute File.exists?(output)
      refute inspect(payload) =~ endpoint
      refute inspect(payload) =~ "secret-vendor"
      refute inspect(payload) =~ model
    end)
  end

  test "canned two-call protocol preserves the fixed tool and synthetic history" do
    on_exit(fn -> Process.delete(:open_responses_protocol_call) end)
    parent = self()

    stream = fn request, opts ->
      send(parent, {:protocol_request, request, opts})

      case Process.get(:open_responses_protocol_call, 0) do
        0 ->
          Process.put(:open_responses_protocol_call, 1)
          {:ok, first_result()}

        1 ->
          Process.put(:open_responses_protocol_call, 2)
          {:ok, second_result()}
      end
    end

    assert {:ok, evidence} =
             Smoke.execute_protocol(stream, :frozen_resolved, %{
               model: "fixture-model",
               timeout_ms: 1234
             })

    assert evidence.calls |> length() == 2
    assert Enum.all?(evidence.calls, & &1["exact_match"])
    assert Enum.all?(evidence.calls, &(&1["terminal"].status == :not_truncated))

    assert_receive {:protocol_request, first_request, first_opts}
    assert_receive {:protocol_request, second_request, second_opts}
    assert first_opts == second_opts
    assert first_opts[:resolved_provider_request] == :frozen_resolved
    assert first_opts[:max_retries] == 0
    assert first_opts[:stream_idle_timeout_ms] == 1234
    assert first_request.tools == second_request.tools
    assert first_request.tools == [Smoke.probe_definition()]
    assert length(first_request.history) == 1

    assert Enum.map(second_request.history, & &1.type) == [
             :user_message,
             :tool_call,
             :tool_result
           ]
  end

  test "first-call rejection stops at one and reports conformance not observed" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stream = fn _request, _opts ->
      Agent.update(calls, &(&1 + 1))
      {:ok, %{first_result() | function_calls: []}}
    end

    assert {:error, %{error: %{kind: :conformance_not_observed}}, 1} =
             Smoke.execute_protocol(stream, :resolved, %{model: "m", timeout_ms: 1})

    assert Agent.get(calls, & &1) == 1
  end

  test "missing done event-match completed or HTTP/SSE evidence cannot produce success" do
    base = first_result()

    invalid_results = [
      put_in(base, [:provider_metadata, "open_responses", "done"], false),
      put_in(base, [:provider_metadata, "open_responses", "event_type_match"], false),
      put_in(
        base,
        [:provider_metadata, "open_responses", "known_event_counts", "response.completed"],
        0
      ),
      put_in(base, [:provider_metadata, "active_transport"], "websocket")
    ]

    for invalid <- invalid_results do
      stream = fn _request, _opts -> {:ok, invalid} end

      assert {:error,
              %{
                error: %{
                  kind: :conformance_not_observed,
                  details: %{reason: :protocol_evidence_missing}
                }
              }, 1} =
               Smoke.execute_protocol(stream, :resolved, %{model: "m", timeout_ms: 1})
    end
  end

  test "eof_after_terminal without the sentinel succeeds and confesses the deviation" do
    tolerate = fn base ->
      base
      |> put_in([:provider_metadata, "open_responses", "done"], false)
      |> put_in([:provider_metadata, "open_responses", "termination"], "eof_after_terminal")
    end

    stream = fn _request, _opts ->
      case Process.get(:open_responses_tolerated_call, 0) do
        0 ->
          Process.put(:open_responses_tolerated_call, 1)
          {:ok, tolerate.(first_result())}

        1 ->
          Process.put(:open_responses_tolerated_call, 2)
          {:ok, tolerate.(second_result())}
      end
    end

    assert {:ok, evidence} =
             Smoke.execute_protocol(stream, :resolved, %{model: "m", timeout_ms: 1})

    assert length(evidence.calls) == 2
    assert Enum.all?(evidence.calls, &(&1["termination"] == "eof_after_terminal"))
    assert Enum.all?(evidence.calls, &(&1["deviations"] == ["missing_done_sentinel"]))
    assert Enum.all?(evidence.calls, &(&1["done"] == false))
  end

  test "done false without a tolerated termination still cannot produce success" do
    base =
      first_result()
      |> put_in([:provider_metadata, "open_responses", "done"], false)
      |> put_in([:provider_metadata, "open_responses", "termination"], "eof_unterminated")

    stream = fn _request, _opts -> {:ok, base} end

    assert {:error,
            %{
              error: %{
                kind: :conformance_not_observed,
                details: %{reason: :protocol_evidence_missing}
              }
            }, 1} =
             Smoke.execute_protocol(stream, :resolved, %{model: "m", timeout_ms: 1})
  end

  test "vendor-specific not_truncated reasons cannot satisfy either smoke call" do
    for invalid <- [
          %{first_result() | output_truncation: OutputTruncation.not_truncated("vendor:other")},
          %{second_result() | output_truncation: OutputTruncation.not_truncated("vendor:other")}
        ] do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      stream = fn _request, _opts ->
        ordinal = Agent.get_and_update(calls, fn count -> {count, count + 1} end)

        case {ordinal, invalid.finish_reason} do
          {0, :tool_calls} -> {:ok, invalid}
          {0, :stop} -> {:ok, first_result()}
          {1, :stop} -> {:ok, invalid}
        end
      end

      assert {:error, %{error: %{kind: :conformance_not_observed}}, attempted_calls} =
               Smoke.execute_protocol(stream, :resolved, %{model: "m", timeout_ms: 1})

      assert attempted_calls in [1, 2]
    end
  end

  test "omitted model uses one Registry snapshot and explicit CLI model remains the override" do
    profile = open_profile("https://snapshot.invalid/v1/responses", %{"policy" => "none"})

    for {args, expected_model} <- [
          {[], "snapshot-model"},
          {["--model", "explicit-model"], "explicit-model"}
        ] do
      {:ok, loads} = Agent.start_link(fn -> 0 end)

      loader = fn _opts ->
        Agent.update(loads, &(&1 + 1))

        {:ok,
         %{
           present?: true,
           origin: :programmatic,
           document: %{"model" => "snapshot-model", "responses_backend" => profile}
         }}
      end

      payload =
        capture_io(fn ->
          assert Smoke.run(["--dry-run", "--json"] ++ args,
                   request_snapshot_loader: loader
                 ) == :ok
        end)
        |> Jason.decode!()

      assert Agent.get(loads, & &1) == 1
      assert payload["model_digest"] == sha256(expected_model)
    end
  end

  test "full canned live task writes bounded atomic 0600 evidence and redacts paths and values" do
    root = tmp_dir("success")
    output = Path.join(root, "secret-output-path")
    endpoint = "https://secret-task-vendor.invalid/v1/responses"
    model = "secret-task-model"
    config = open_config(endpoint, model)

    stdout =
      capture_io(fn ->
        assert Smoke.run(["--json", "--output", output],
                 raw_config: config,
                 stream_fun: canned_protocol_stream()
               ) == :ok
      end)

    payload = one_json_object(stdout)
    assert payload["ok"] == true
    assert payload["mode"] == "live"
    assert payload["completed_calls"] == 2
    assert payload["artifact"]["basename"] == "open-responses-evidence.json"

    evidence_path = Path.join(output, payload["artifact"]["basename"])
    encoded = File.read!(evidence_path)
    stat = File.stat!(evidence_path)

    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert byte_size(encoded) == payload["artifact"]["bytes"]
    assert sha256(encoded) == payload["artifact"]["sha256"]
    assert byte_size(encoded) <= 32_768
    assert File.ls!(output) == ["open-responses-evidence.json"]

    for secret <- [endpoint, "secret-task-vendor", model, output, root] do
      refute stdout =~ secret
      refute encoded =~ secret
    end

    human =
      capture_io(fn ->
        assert Smoke.run(["--output", Path.join(root, "human")],
                 raw_config: config,
                 stream_fun: canned_protocol_stream()
               ) == :ok
      end)

    assert human =~ "mix pixir.smoke.open_responses: endpoint_compatibility_observed; calls=2"
    refute human =~ endpoint
    refute human =~ model
    refute human =~ root
  end

  test "20KiB task errors are absent from JSON human channels Inspect and evidence" do
    root = tmp_dir("error")
    output = Path.join(root, "must-not-be-written")
    sentinel = String.duplicate("TASK-REMOTE-SENTINEL-", 1_024)
    config = open_config("https://task-error.invalid/v1/responses", "task-error-model")

    stream = fn _request, _opts ->
      {:error,
       %{
         error: %{
           kind: :provider_http_error,
           message: sentinel,
           details: %{reason: sentinel, remote: sentinel}
         }
       }}
    end

    stdout =
      capture_io(fn ->
        assert catch_exit(
                 Smoke.run(["--json", "--output", output],
                   raw_config: config,
                   stream_fun: stream
                 )
               ) == {:shutdown, 1}
      end)

    payload = one_json_object(stdout)
    assert payload["ok"] == false
    assert payload["status"] == "provider_error"
    refute stdout =~ sentinel
    refute inspect(payload) =~ sentinel
    refute File.exists?(output)

    stderr =
      capture_io(:stderr, fn ->
        assert catch_exit(Smoke.run(["--output", output], raw_config: config, stream_fun: stream)) ==
                 {:shutdown, 1}
      end)

    refute stderr =~ sentinel
    assert stderr =~ "provider_http_error: The Open Responses Provider attempt failed."
    refute File.exists?(output)
  end

  test "schema-invalid families fail the full task and write no success evidence" do
    root = tmp_dir("malformed")
    config = open_config("https://task-malformed.invalid/v1/responses", "task-model")

    malformed_streams = [
      {:missing_text_coordinates,
       "event: response.output_text.delta\n" <>
         "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":1,\"delta\":\"x\"}\n\n"},
      {:empty_usage, task_completed_stream(%{"usage" => %{}})},
      {:terminal_null_item, task_completed_stream(%{"output" => [nil]})},
      {:instructions_list, task_completed_stream(%{"instructions" => []})},
      {:empty_response_error, task_completed_stream(%{"error" => %{}})}
    ]

    family_labels =
      Enum.map(
        [
          "IncompleteDetails",
          "Tool",
          "ToolChoice.FunctionToolChoice",
          "ToolChoice.ToolChoiceValueEnum",
          "ToolChoice.AllowedToolChoice",
          "Truncation",
          "TextField",
          "TextResponseFormat",
          "JsonObjectResponseFormat",
          "JsonSchemaResponseFormat",
          "Reasoning",
          "Usage",
          "Error",
          "MessageContent",
          "FunctionCall"
        ],
        &"invalid:family:#{&1}:response.completed"
      ) ++ ["invalid:family:Annotation", "invalid:family:LogProb"]

    corpus = corpus_by_label()

    malformed_streams =
      malformed_streams ++
        Enum.map(family_labels, fn label ->
          event = corpus[label]["event"]

          {label, "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\ndata: [DONE]\n\n"}
        end)

    for {{name, malformed}, index} <- Enum.with_index(malformed_streams) do
      output = Path.join(root, "invalid-#{index}")

      transport = fn _request, acc, fun ->
        acc = fun.({:status, 200}, acc)
        {:ok, fun.({:data, malformed}, acc)}
      end

      stream = fn request, opts ->
        Provider.stream(request, Keyword.put(opts, :transport, transport))
      end

      stdout =
        capture_io(fn ->
          assert catch_exit(
                   Smoke.run(["--json", "--output", output],
                     raw_config: config,
                     stream_fun: stream
                   )
                 ) == {:shutdown, 1}
        end)

      payload = one_json_object(stdout)
      assert payload["ok"] == false
      assert payload["error"]["details"]["reason"] == "invalid_event_shape"
      refute File.exists?(output)
      assert is_atom(name) or is_binary(name)
    end
  end

  test "conformant minimal response failed reaches bounded task provider failure" do
    root = tmp_dir("response-failed")
    output = Path.join(root, "must-not-be-written")
    config = open_config("https://task-failed.invalid/v1/responses", "task-model")

    failed =
      task_response_stream("response.failed", %{
        "status" => "failed",
        "error" => %{"code" => "server_error", "message" => "remote failure"}
      })

    transport = fn _request, acc, fun ->
      acc = fun.({:status, 200}, acc)
      {:ok, fun.({:data, failed}, acc)}
    end

    stream = fn request, opts ->
      Provider.stream(request, Keyword.put(opts, :transport, transport))
    end

    stdout =
      capture_io(fn ->
        assert catch_exit(
                 Smoke.run(["--json", "--output", output],
                   raw_config: config,
                   stream_fun: stream
                 )
               ) == {:shutdown, 1}
      end)

    payload = one_json_object(stdout)
    assert payload["ok"] == false
    assert payload["status"] == "provider_error"
    assert payload["error"]["kind"] == "provider_http_error"
    refute stdout =~ "remote failure"
    refute File.exists?(output)
  end

  test "failed evidence replacement leaves no temporary success artifact" do
    root = tmp_dir("atomic-failure")
    output_file = Path.join(root, "not-a-directory")
    File.write!(output_file, "preserve-me")

    stdout =
      capture_io(fn ->
        assert catch_exit(
                 Smoke.run(["--json", "--output", output_file],
                   raw_config:
                     open_config(
                       "https://task-write.invalid/v1/responses",
                       "task-write-model"
                     ),
                   stream_fun: canned_protocol_stream()
                 )
               ) == {:shutdown, 1}
      end)

    assert one_json_object(stdout)["ok"] == false
    assert File.read!(output_file) == "preserve-me"
    assert File.ls!(root) == ["not-a-directory"]
  end

  test "bearer and auth-none claims stay distinct" do
    assert Smoke.claim_for_auth(:none) == {"endpoint_compatibility_observed", false}

    assert Smoke.claim_for_auth({:bearer_env, "TOKEN"}) ==
             {"interoperability_observed", true}
  end

  test "missing canonical open profile is invalid_config with exit 2" do
    with_config(Jason.encode!(%{}), fn _home ->
      payload =
        capture_io(fn ->
          assert catch_exit(Smoke.run(["--dry-run", "--json"])) == {:shutdown, 2}
        end)
        |> Jason.decode!()

      assert payload["ok"] == false
      assert payload["status"] == "invalid_config"
      assert payload["error"]["kind"] == "invalid_config"
    end)
  end

  defp first_result do
    result(
      "",
      [
        %{
          call_id: "call_probe",
          name: "pixir_open_responses_probe",
          args: %{"probe" => "open-responses-v1"}
        }
      ],
      :tool_calls
    )
  end

  defp second_result, do: result("PIXIR_OPEN_RESPONSES_OK_V1", [], :stop)

  defp result(text, calls, finish_reason) do
    %{
      text: text,
      reasoning: "",
      reasoning_items: [],
      function_calls: calls,
      finish_reason: finish_reason,
      output_truncation: OutputTruncation.not_truncated("response.completed"),
      usage_summary: %{
        input_tokens: 1,
        cached_tokens: 0,
        output_tokens: 1,
        reasoning_tokens: 0,
        total_tokens: 2
      },
      provider_metadata: %{
        "active_transport" => "http_sse",
        "open_responses" => %{
          "known_event_counts" => %{"response.completed" => 1},
          "event_type_match" => true,
          "done" => true
        }
      }
    }
  end

  defp open_profile(endpoint, auth) do
    %{
      "mode" => "open_responses",
      "responses_url" => endpoint,
      "auth" => auth
    }
  end

  defp open_config(endpoint, model) do
    %{
      "model" => model,
      "responses_backend" => open_profile(endpoint, %{"policy" => "none"})
    }
  end

  defp canned_protocol_stream do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    fn _request, _opts ->
      case Agent.get_and_update(calls, fn count -> {count, count + 1} end) do
        0 -> {:ok, first_result()}
        1 -> {:ok, second_result()}
      end
    end
  end

  defp task_completed_stream(response_overrides) do
    task_response_stream("response.completed", response_overrides)
  end

  defp task_response_stream(type, response_overrides) do
    body = %{
      "type" => type,
      "sequence_number" => 1,
      "response" => Map.merge(task_response_resource(), response_overrides)
    }

    "event: #{type}\ndata: #{Jason.encode!(body)}\n\ndata: [DONE]\n\n"
  end

  defp task_response_resource do
    %{
      "id" => "resp_task",
      "object" => "response",
      "created_at" => 1,
      "completed_at" => 2,
      "status" => "completed",
      "incomplete_details" => nil,
      "model" => "task-model",
      "previous_response_id" => nil,
      "instructions" => "task instructions",
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
      "usage" => %{
        "input_tokens" => 0,
        "output_tokens" => 0,
        "total_tokens" => 0,
        "input_tokens_details" => %{"cached_tokens" => 0},
        "output_tokens_details" => %{"reasoning_tokens" => 0}
      },
      "max_output_tokens" => nil,
      "max_tool_calls" => nil,
      "store" => false,
      "background" => false,
      "service_tier" => "default",
      "metadata" => %{},
      "safety_identifier" => nil,
      "prompt_cache_key" => nil
    }
  end

  defp one_json_object(stdout) do
    assert [line] = String.split(String.trim(stdout), "\n", trim: true)
    Jason.decode!(line)
  end

  defp corpus_by_label do
    bases = @schema_corpus_bases |> File.read!() |> Jason.decode!()

    @schema_corpus
    |> File.stream!(:line, [])
    |> Map.new(fn line ->
      row = Jason.decode!(line)
      row = Map.put(row, "event", expand_recipe!(Map.fetch!(bases, row["base"]), row["ops"]))
      {row["label"], row}
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

  defp tmp_dir(suffix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-open-task-#{suffix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp with_config(contents, fun) do
    home = Path.join(System.tmp_dir!(), "pixir-open-smoke-#{System.unique_integer([:positive])}")
    prior_home = System.get_env("PIXIR_HOME")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.json"), contents)
    System.put_env("PIXIR_HOME", home)

    try do
      fun.(home)
    after
      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(home)
    end
  end
end
