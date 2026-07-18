defmodule Pixir.ProviderTest do
  use ExUnit.Case, async: false

  alias Pixir.{Auth, Event, Provider}

  @default_body_golden ~S({"include":["reasoning.encrypted_content"],"input":[],"instructions":"You are a helpful coding assistant.","model":"gpt-5.5","parallel_tool_calls":true,"store":false,"stream":true,"tool_choice":"auto"})

  setup do
    name = :"auth_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "pixir-prov-#{System.unique_integer([:positive])}.json")

    {:ok, _} =
      Auth.start_link(
        name: name,
        store_path: path,
        env_api_key: "sk-test",
        oauth: __MODULE__.NoOAuth
      )

    on_exit(fn -> File.rm_rf!(path) end)
    %{auth: name}
  end

  defmodule NoOAuth do
    def refresh_skew_ms, do: 60_000
  end

  defmodule RotatingHeaderAuth do
    use GenServer

    def start_link(tokens), do: GenServer.start_link(__MODULE__, tokens)
    def init(tokens), do: {:ok, tokens}

    def handle_call(:request_headers, _from, [token | rest]) do
      {:reply, {:ok, [{"authorization", "Bearer " <> token}]}, rest}
    end
  end

  defmodule StaticHeaderAuth do
    use GenServer

    def start_link(headers), do: GenServer.start_link(__MODULE__, headers)
    def init(headers), do: {:ok, headers}
    def handle_call(:request_headers, _from, headers), do: {:reply, {:ok, headers}, headers}
  end

  defmodule UnloadedInspectProvider do
    @on_load :mark_loaded

    def mark_loaded do
      :persistent_term.put({__MODULE__, :loaded}, true)
      :ok
    end

    def stream(_request, _opts), do: {:error, :not_called}
  end

  # A transport that records the request and replays canned SSE blocks.
  defp canned(chunks, status \\ 200) do
    test = self()

    fn http_request, acc, fun ->
      send(test, {:request, http_request})
      acc = fun.({:status, status}, acc)
      acc = Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      {:ok, acc}
    end
  end

  defp canned_attempts(attempts) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> :queue.from_list(attempts) end)

    fn http_request, acc, fun ->
      send(test, {:request, http_request})

      {chunks, status} =
        Agent.get_and_update(agent, fn queue ->
          case :queue.out(queue) do
            {{:value, {chunks, status}}, rest} -> {{chunks, status}, rest}
            {{:value, chunks}, rest} -> {{chunks, 200}, rest}
            {:empty, empty} -> raise "no canned provider attempt left: #{inspect(empty)}"
          end
        end)

      acc = fun.({:status, status}, acc)
      acc = Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
      {:ok, acc}
    end
  end

  defp error_body_cases do
    cap = Pixir.Providers.ErrBody.max_bytes()

    [
      {"under", [String.duplicate("u", cap - 1)], false},
      {"exact", [String.duplicate("e", cap)], false},
      {"exact_chunked", [String.duplicate("c", div(cap, 2)), String.duplicate("d", div(cap, 2))],
       false},
      {"exact_then_empty", [String.duplicate("z", cap), ""], false},
      {"exact_then_one", [String.duplicate("y", cap), "x"], true},
      {"over_then_empty", [String.duplicate("p", cap - 1), "qr", ""], true},
      {"over_chunked", [String.duplicate("p", cap - 1), "qr", "later"], true}
    ]
  end

  defp expected_error_prefix(chunks) do
    body = IO.iodata_to_binary(chunks)
    binary_part(body, 0, min(byte_size(body), Pixir.Providers.ErrBody.max_bytes()))
  end

  defp sse(map), do: "data: " <> Jason.encode!(map) <> "\n\n"

  defp tmp_workspace do
    path =
      Path.join(
        System.tmp_dir!(),
        "pixir-provider-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    File.mkdir_p!(path)
    path
  end

  defp fold_raw_history!(session_id, raw_ndjson) do
    workspace = tmp_workspace()
    log_path = Pixir.Log.path(session_id, workspace: workspace)
    File.mkdir_p!(Path.dirname(log_path))
    File.write!(log_path, raw_ndjson)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, history} = Pixir.Log.fold(session_id, workspace: workspace)
    {history, workspace}
  end

  test "assembles streamed text and reports a stop finish", %{auth: auth} do
    parent = self()

    chunks = [
      sse(%{type: "response.output_text.delta", delta: "Hello"}),
      sse(%{type: "response.output_text.delta", delta: ", world"}),
      sse(%{type: "response.completed"})
    ]

    request = %{system_prompt: "sys", history: [Event.user_message("s", "hi")]}

    assert {:ok, result} =
             Provider.stream(request,
               auth: auth,
               transport: canned(chunks),
               on_delta: fn d -> send(parent, {:delta, d}) end
             )

    assert result.text == "Hello, world"
    assert result.finish_reason == :stop
    assert result.function_calls == []
    assert result.usage == nil
    assert result.usage_summary.cached_tokens == 0

    assert_received {:delta, {:text_delta, "Hello"}}
    assert_received {:delta, {:text_delta, ", world"}}
  end

  test "captures response.completed usage and summarizes prompt-cache details", %{auth: auth} do
    usage = %{
      input_tokens: 2006,
      input_tokens_details: %{cached_tokens: 1920},
      output_tokens: 300,
      output_tokens_details: %{reasoning_tokens: 42},
      total_tokens: 2306
    }

    chunks = [
      sse(%{type: "response.output_text.delta", delta: "ok"}),
      sse(%{type: "response.completed", response: %{usage: usage}})
    ]

    assert {:ok, result} = Provider.stream(%{history: []}, auth: auth, transport: canned(chunks))

    assert result.usage["input_tokens"] == 2006

    assert result.usage_summary == %{
             input_tokens: 2006,
             cached_tokens: 1920,
             output_tokens: 300,
             reasoning_tokens: 42,
             total_tokens: 2306,
             cache_hit_rate: 1920 / 2006,
             cache: %{"creation_tokens" => 0, "read_tokens" => 1920}
           }
  end

  test "summarizes legacy prompt/completion usage names", %{auth: auth} do
    usage = %{
      prompt_tokens: 1200,
      prompt_tokens_details: %{cached_tokens: 1024},
      completion_tokens: 80,
      completion_tokens_details: %{reasoning_tokens: 12},
      total_tokens: 1280
    }

    assert {:ok, result} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned([sse(%{type: "response.completed", response: %{usage: usage}})])
             )

    assert result.usage_summary.input_tokens == 1200
    assert result.usage_summary.cached_tokens == 1024
    assert result.usage_summary.output_tokens == 80
    assert result.usage_summary.reasoning_tokens == 12
  end

  test "surfaces function_call items with parsed args and a tool_calls finish", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.output_item.done",
        item: %{
          type: "function_call",
          call_id: "call_1",
          name: "read",
          arguments: ~s({"path":"a.txt"})
        }
      }),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, result} = Provider.stream(%{history: []}, auth: auth, transport: canned(chunks))
    assert result.finish_reason == :tool_calls

    assert [%{call_id: "call_1", name: "read", args: %{"path" => "a.txt"}}] =
             result.function_calls
  end

  test "emits reasoning deltas to the callback", %{auth: auth} do
    parent = self()

    chunks = [
      sse(%{type: "response.reasoning_summary_text.delta", delta: "thinking..."}),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, result} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(chunks),
               on_delta: fn d -> send(parent, {:d, d}) end
             )

    assert result.reasoning == "thinking..."
    assert_received {:d, {:reasoning_delta, "thinking..."}}
  end

  test "handles SSE blocks split across transport chunks", %{auth: auth} do
    full = sse(%{type: "response.output_text.delta", delta: "split"})
    {a, b} = String.split_at(full, 10)
    chunks = [a, b, sse(%{type: "response.completed"})]

    assert {:ok, %{text: "split"}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned(chunks))
  end

  test "response.failed stream events become structured provider errors", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.failed",
        response: %{
          error: %{
            code: "server_error",
            message: "tool schema failed",
            type: "server_error",
            param: nil
          }
        }
      })
    ]

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                message: "tool schema failed",
                details: %{
                  status: 200,
                  event_type: "response.failed",
                  code: "server_error",
                  type: "server_error"
                }
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(chunks),
               max_retries: 0
             )
  end

  test "retryable in-band transient stream error retries and succeeds", %{auth: auth} do
    overloaded =
      sse(%{
        type: "error",
        error: %{
          code: "server_is_overloaded",
          type: "service_unavailable_error",
          message: "Our servers are currently overloaded."
        }
      })

    success = [
      sse(%{type: "response.output_text.delta", delta: "ok"}),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, %{text: "ok"}} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned_attempts([[overloaded], success]),
               max_retries: 1,
               sleep: fn _ -> :ok end
             )

    assert_received {:request, _}
    assert_received {:request, _}
  end

  test "retryable in-band transient stream error stamps retryable details", %{auth: auth} do
    chunks = [
      sse(%{
        type: "error",
        error: %{
          code: "server_is_overloaded",
          type: "service_unavailable_error",
          message: "Our servers are currently overloaded."
        }
      })
    ]

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: %{status: 200, event_type: "error", retryable: true}
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(chunks),
               max_retries: 0
             )
  end

  test "non-transient in-band stream error is not retryable", %{auth: auth} do
    chunks = [
      sse(%{
        type: "error",
        error: %{
          code: "invalid_request",
          type: "invalid_request_error",
          message: "Invalid request."
        }
      })
    ]

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: details
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(chunks),
               max_retries: 1,
               sleep: fn _ -> :ok end
             )

    assert details.status == 200
    assert details.event_type == "error"
    refute Map.has_key?(details, :retryable)
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "in-band overflow rejections on a 200 stream get kind :context_overflow", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.failed",
        response: %{
          error: %{
            code: "context_length_exceeded",
            message: "Your input exceeds the context window of this model.",
            type: "invalid_request_error",
            param: nil
          }
        }
      })
    ]

    assert {:error,
            %{
              error: %{
                kind: :context_overflow,
                details: %{
                  status: 200,
                  event_type: "response.failed",
                  code: "context_length_exceeded"
                }
              }
            }} = Provider.stream(%{history: []}, auth: auth, transport: canned(chunks))
  end

  test "in-band stream error does not infer overflow from message alone", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.failed",
        response: %{
          error: %{
            code: "server_error",
            message: "Transient context window routing failure.",
            type: "server_error"
          }
        }
      })
    ]

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: %{
                  status: 200,
                  event_type: "response.failed",
                  code: "server_error",
                  type: "server_error"
                }
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(chunks),
               max_retries: 0
             )
  end

  test "oversized non-2xx error body is capped and marked truncated", %{auth: auth} do
    payload = String.duplicate("x", Pixir.Providers.ErrBody.max_bytes() * 2)
    body = Jason.encode!(%{error: %{type: "server_error", message: payload}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                message: message,
                details: details
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned([body], 500),
               max_retries: 0
             )

    assert details.err_body_truncated == true
    assert byte_size(details.body) <= Pixir.Providers.ErrBody.max_bytes()
    refute message =~ payload
    refute inspect(details) =~ payload
  end

  test "small non-2xx error body does not carry truncation marker", %{auth: auth} do
    body = Jason.encode!(%{error: %{type: "server_error", message: "small failure"}})

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: details
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned([body], 500),
               max_retries: 0
             )

    refute Map.has_key?(details, :err_body_truncated)
  end

  test "non-2xx error-body provenance is exact across cap and chunk boundaries", %{auth: auth} do
    for {name, chunks, expected_truncated} <- error_body_cases() do
      assert {:error, %{error: %{kind: :provider_http_error, details: details}}} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: canned(chunks, 500),
                 max_retries: 0
               ),
             name

      assert details.body == expected_error_prefix(chunks), name
      assert byte_size(details.body) <= Pixir.Providers.ErrBody.max_bytes(), name
      assert Map.has_key?(details, :err_body_truncated) == expected_truncated, name

      if expected_truncated do
        assert details.err_body_truncated == true, name
      end
    end
  end

  test "retry starts a fresh error-body capture", %{auth: auth} do
    cap = Pixir.Providers.ErrBody.max_bytes()
    overflow = String.duplicate("x", cap + 1)
    exact = String.duplicate("e", cap)

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                details: %{status: 400, body: ^exact} = details
              }
            }} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned_attempts([{[overflow], 500}, {[exact], 400}]),
               max_retries: 1,
               sleep: fn _ -> :ok end
             )

    refute Map.has_key?(details, :err_body_truncated)
    assert_received {:request, _}
    assert_received {:request, _}
    refute_received {:request, _}
  end

  test "folds History into Responses input items", %{auth: auth} do
    history = [
      Event.user_message("s", "read the file"),
      Event.tool_call("s", "call_1", "read", %{"path" => "a.txt"}),
      Event.tool_result("s", "call_1", %{"ok" => true, "output" => "file contents"}),
      Event.assistant_message("s", "done")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    decoded = Jason.decode!(body)
    assert decoded["store"] == false
    assert decoded["stream"] == true

    assert [user, call, result, assistant] = decoded["input"]

    assert user == %{
             "role" => "user",
             "content" => [%{"type" => "input_text", "text" => "read the file"}]
           }

    assert call["type"] == "function_call"
    assert call["call_id"] == "call_1"
    assert Jason.decode!(call["arguments"]) == %{"path" => "a.txt"}

    assert result == %{
             "type" => "function_call_output",
             "call_id" => "call_1",
             "output" => "file contents"
           }

    assert assistant["type"] == "message"
    assert assistant["role"] == "assistant"
  end

  test "does not replay partial assistant evidence as final assistant input", %{auth: auth} do
    history = [
      Event.user_message("s", "start"),
      Event.assistant_message("s", "partial visible answer",
        metadata: %{
          "partial" => true,
          "terminal_status" => "provider_error",
          "error_kind" => "network"
        }
      ),
      Event.user_message("s", "continue")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    input = Jason.decode!(body)["input"]

    assert Enum.map(input, & &1["role"]) == ["user", "user"]

    refute Enum.any?(input, fn item ->
             item["role"] == "assistant" and
               get_in(item, ["content", Access.at(0), "text"]) == "partial visible answer"
           end)
  end

  test "projects resources on the current user turn as input_image", %{auth: auth} do
    ws = tmp_workspace()
    sid = "s"
    bytes = "image bytes"

    try do
      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
          sid,
          [
            %{
              "type" => "image",
              "name" => "screen.png",
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
            }
          ],
          workspace: ws
        )

      history = [Event.user_message(sid, "what is shown?", resources: [descriptor])]

      {:ok, _} =
        Provider.stream(%{history: history, workspace: ws},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      assert [%{"content" => content}] = Jason.decode!(body)["input"]

      assert Enum.any?(
               content,
               &match?(%{"type" => "input_text", "text" => "what is shown?"}, &1)
             )

      assert [%{"type" => "input_image", "image_url" => image_url, "detail" => "auto"}] =
               Enum.filter(content, &(&1["type"] == "input_image"))

      assert image_url == "data:image/png;base64,#{Base.encode64(bytes)}"
    after
      File.rm_rf!(ws)
    end
  end

  test "describes current non-image resources instead of dropping them", %{auth: auth} do
    ws = tmp_workspace()
    sid = "s"
    file_path = Path.join(ws, "notes.txt")
    File.write!(file_path, "notes")

    try do
      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
          sid,
          [
            %{
              "type" => "resource_link",
              "uri" => "file://#{file_path}",
              "name" => "notes.txt",
              "mimeType" => "text/plain"
            }
          ],
          workspace: ws
        )

      history = [Event.user_message(sid, "use this file", resources: [descriptor])]

      {:ok, _} =
        Provider.stream(%{history: history, workspace: ws},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      assert [%{"content" => content}] = Jason.decode!(body)["input"]
      assert [%{"type" => "input_text", "text" => text}] = content
      assert text =~ "use this file"
      assert text =~ "Attached resources:"
      assert text =~ descriptor["resource_id"]
      refute text =~ "file://"
    after
      File.rm_rf!(ws)
    end
  end

  test "replays older resources as descriptors instead of input_image", %{auth: auth} do
    ws = tmp_workspace()
    sid = "s"

    try do
      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
          sid,
          [
            %{
              "type" => "image",
              "name" => "screen.png",
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{Base.encode64("bytes")}"
            }
          ],
          workspace: ws
        )

      history = [
        Event.user_message(sid, "old visual question", resources: [descriptor])
        |> Event.with_seq(0),
        Event.assistant_message(sid, "answered") |> Event.with_seq(1),
        Event.user_message(sid, "continue") |> Event.with_seq(2)
      ]

      {:ok, _} =
        Provider.stream(%{history: history, workspace: ws},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      assert [first_user, _assistant, second_user] = Jason.decode!(body)["input"]
      first_content = first_user["content"]
      refute Enum.any?(first_content, &(&1["type"] == "input_image"))
      assert hd(first_content)["text"] =~ descriptor["resource_id"]
      assert second_user["content"] == [%{"type" => "input_text", "text" => "continue"}]
    after
      File.rm_rf!(ws)
    end
  end

  test "resource_view tool results rehydrate images on the next provider call", %{auth: auth} do
    ws = tmp_workspace()
    sid = "s"
    bytes = "bytes"

    try do
      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
          sid,
          [
            %{
              "type" => "image",
              "name" => "screen.png",
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{Base.encode64(bytes)}"
            }
          ],
          workspace: ws
        )

      history = [
        Event.user_message(sid, "old visual question", resources: [descriptor])
        |> Event.with_seq(0),
        Event.assistant_message(sid, "answered") |> Event.with_seq(1),
        Event.user_message(sid, "look exactly") |> Event.with_seq(2),
        Event.tool_call(sid, "call_1", "resource_view", %{
          "resource_id" => descriptor["resource_id"]
        })
        |> Event.with_seq(3),
        Event.tool_result(sid, "call_1", %{
          "ok" => true,
          "output" => "Resource is available.",
          "resource_view" => %{
            "descriptor" => descriptor,
            "resource_id" => descriptor["resource_id"]
          }
        })
        |> Event.with_seq(4)
      ]

      {:ok, _} =
        Provider.stream(%{history: history, workspace: ws},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      input = Jason.decode!(body)["input"]

      assert [%{"role" => "user", "content" => view_content}] =
               Enum.filter(input, fn item ->
                 item["role"] == "user" and
                   match?([%{"text" => "Resource view requested:" <> _} | _], item["content"])
               end)

      assert [%{"type" => "input_image", "image_url" => image_url}] =
               Enum.filter(view_content, &(&1["type"] == "input_image"))

      assert image_url == "data:image/png;base64,#{Base.encode64(bytes)}"
    after
      File.rm_rf!(ws)
    end
  end

  test "older resource_view tool results do not rehydrate images after a later user turn", %{
    auth: auth
  } do
    ws = tmp_workspace()
    sid = "s"

    try do
      {:ok, [descriptor]} =
        Pixir.SessionResources.ingest_attachments(
          sid,
          [
            %{
              "type" => "image",
              "name" => "screen.png",
              "mimeType" => "image/png",
              "dataUrl" => "data:image/png;base64,#{Base.encode64("bytes")}"
            }
          ],
          workspace: ws
        )

      history = [
        Event.user_message(sid, "old visual question", resources: [descriptor])
        |> Event.with_seq(0),
        Event.assistant_message(sid, "answered") |> Event.with_seq(1),
        Event.user_message(sid, "look exactly") |> Event.with_seq(2),
        Event.tool_call(sid, "call_1", "resource_view", %{
          "resource_id" => descriptor["resource_id"]
        })
        |> Event.with_seq(3),
        Event.tool_result(sid, "call_1", %{
          "ok" => true,
          "output" => "Resource is available.",
          "resource_view" => %{
            "descriptor" => descriptor,
            "resource_id" => descriptor["resource_id"]
          }
        })
        |> Event.with_seq(4),
        Event.assistant_message(sid, "The image says PIXIR BLUE 42.") |> Event.with_seq(5),
        Event.user_message(sid, "continue without looking again") |> Event.with_seq(6)
      ]

      {:ok, _} =
        Provider.stream(%{history: history, workspace: ws},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      input = Jason.decode!(body)["input"]

      refute input
             |> Enum.flat_map(fn item -> item["content"] || [] end)
             |> Enum.any?(&(&1["type"] == "input_image"))
    after
      File.rm_rf!(ws)
    end
  end

  test "prepends developer context ahead of folded History (px2, ADR 0020)", %{auth: auth} do
    history = [Event.user_message("s", "hello")]

    {:ok, _} =
      Provider.stream(
        %{
          history: history,
          developer_context: "Developer context: the workspace root is /tmp/ws. Mode: build."
        },
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [developer, user] = Jason.decode!(body)["input"]

    assert developer == %{
             "role" => "developer",
             "content" => [
               %{
                 "type" => "input_text",
                 "text" => "Developer context: the workspace root is /tmp/ws. Mode: build."
               }
             ]
           }

    assert user["role"] == "user"
  end

  test "omits the developer item when no developer context is given", %{auth: auth} do
    for absent <- [nil, "", "  \n"] do
      {:ok, _} =
        Provider.stream(%{history: [Event.user_message("s", "hi")], developer_context: absent},
          auth: auth,
          transport: canned([sse(%{type: "response.completed"})])
        )

      assert_received {:request, %{body: body}}
      assert [user] = Jason.decode!(body)["input"]
      assert user["role"] == "user"
    end
  end

  test "does not replay provider_usage events as model input", %{auth: auth} do
    history = [
      Event.user_message("s", "hello"),
      Event.provider_usage("s", %{
        "model" => "gpt-5.5",
        "call_index" => 0,
        "usage_summary" => %{"input_tokens" => 111, "cached_tokens" => 100},
        "provider_hosted_tools" => %{
          "web_search" => %{
            "call_count" => 1,
            "annotations" => [%{"type" => "url_citation", "url" => "https://example.com"}]
          }
        }
      }),
      Event.assistant_message("s", "done")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [user, assistant] = Jason.decode!(body)["input"]
    assert user["role"] == "user"
    assert assistant["role"] == "assistant"
  end

  test "does not replay turn_failed audit evidence as model input", %{auth: auth} do
    history = [
      Event.user_message("s", "hello"),
      Event.turn_failed("s", %{
        "terminal_status" => "provider_error",
        "error_kind" => "network",
        "error_message" => "The provider stream exited before Pixir received a final answer.",
        "details" => %{"transport" => "websocket"}
      }),
      Event.user_message("s", "continue")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    input = Jason.decode!(body)["input"]

    assert Enum.map(input, & &1["role"]) == ["user", "user"]

    refute Enum.any?(input, fn item ->
             item["role"] == "user" and
               get_in(item, ["content", Access.at(0), "text"]) =~ "provider stream"
           end)
  end

  test "does not replay partial assistant plus turn_failed evidence as model input", %{auth: auth} do
    history = [
      Event.user_message("s", "hello"),
      Event.assistant_message("s", "partial answer",
        metadata: %{
          "partial" => true,
          "terminal_status" => "provider_error",
          "error_kind" => "network"
        }
      ),
      Event.turn_failed("s", %{
        "terminal_status" => "provider_error",
        "error_kind" => "network",
        "error_message" => "The provider stream exited before Pixir received a final answer.",
        "details" => %{"transport" => "websocket", "partial_text_length" => 14}
      }),
      Event.user_message("s", "continue")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    input = Jason.decode!(body)["input"]

    assert Enum.map(input, & &1["role"]) == ["user", "user"]
  end

  test "folds orphan tool calls with a synthetic output instead of replaying invalid history",
       %{auth: auth} do
    history = [
      Event.user_message("s", "run grep"),
      Event.tool_call("s", "call_orphan", "bash", %{"command" => "grep something"}),
      Event.user_message("s", "continue")
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    decoded = Jason.decode!(body)

    assert [first_user, call, synthetic_output, second_user] = decoded["input"]
    assert first_user["role"] == "user"
    assert call["type"] == "function_call"
    assert call["call_id"] == "call_orphan"

    assert synthetic_output["type"] == "function_call_output"
    assert synthetic_output["call_id"] == "call_orphan"

    assert %{"ok" => false, "error" => %{"kind" => "orphan_tool_call"}} =
             Jason.decode!(synthetic_output["output"])

    assert second_user["role"] == "user"
    assert second_user["content"] == [%{"type" => "input_text", "text" => "continue"}]
  end

  test "does not synthesize orphans for lifecycle events between tool call and result" do
    history = [
      Event.user_message("s", "spawn"),
      Event.tool_call("s", "call_spawn", "spawn_agent", %{"task" => "inspect"}),
      Event.subagent_event("s", %{
        "event" => "started",
        "subagent_id" => "sub_1",
        "agent" => "explorer",
        "status" => "running"
      }),
      Event.workflow_event("s", %{
        "kind" => "step_scheduled",
        "workflow_id" => "wf",
        "step_id" => "inspect"
      }),
      Event.tool_result("s", "call_spawn", %{"ok" => true, "output" => "spawned"}),
      Event.tool_call("s", "call_read", "read", %{"path" => "README.md"}),
      Event.permission_decision("s", "call_read", :allow),
      Event.tool_result("s", "call_read", %{"ok" => true, "output" => "body"})
    ]

    assert {:ok, body} = Provider.request_body_preview(%{history: history})

    function_calls = Enum.filter(body["input"], &(Map.get(&1, "type") == "function_call"))
    outputs = Enum.filter(body["input"], &(Map.get(&1, "type") == "function_call_output"))

    assert Enum.map(function_calls, & &1["call_id"]) == ["call_spawn", "call_read"]
    assert Enum.map(outputs, & &1["call_id"]) == ["call_spawn", "call_read"]
    assert length(body["input"]) == 5

    refute Enum.any?(outputs, fn %{"output" => output} ->
             match?({:ok, %{"error" => %{"kind" => "orphan_tool_call"}}}, Jason.decode(output))
           end)
  end

  test "pairs a skill_view result across its canonical skill activation", %{auth: auth} do
    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "activation-hash",
      "content" => "# Diagnose\n\nInspect evidence first."
    }

    history = [
      Event.user_message("s", "diagnose this"),
      Event.tool_call("s", "call_skill", "skill_view", %{"name" => "diagnose"}),
      Event.skill_activation("s", activation),
      Event.tool_result("s", "call_skill", %{
        "ok" => true,
        "activated" => true,
        "content_hash" => "activation-hash"
      })
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    input = Jason.decode!(body)["input"]

    assert output = Enum.find(input, &(&1["type"] == "function_call_output"))

    assert %{"ok" => true, "content_hash" => "activation-hash"} =
             Jason.decode!(output["output"])

    refute Enum.any?(input, fn
             %{"type" => "function_call_output", "output" => output} ->
               match?(
                 {:ok, %{"error" => %{"kind" => "orphan_tool_call"}}},
                 Jason.decode(output)
               )

             _item ->
               false
           end)
  end

  test "emits a deferred skill activation after its matched result with exact snapshot" do
    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "exact-logged-hash",
      "content" => "# Exact logged instructions"
    }

    history = [
      Event.tool_call("s", "call_skill", "skill_view", %{
        "name" => "diagnose",
        "path" => "SKILL.md"
      }),
      Event.skill_activation("s", activation),
      Event.tool_result("s", "call_skill", %{"ok" => true})
    ]

    assert {:ok, body} = Provider.request_body_preview(%{history: history})
    assert [call, output, projected_activation] = body["input"]
    assert call["call_id"] == "call_skill"
    assert output["type"] == "function_call_output"
    assert Jason.decode!(output["output"])["ok"] == true

    assert projected_activation == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "input_text",
                 "text" => Pixir.Skills.render_activation(activation)
               }
             ]
           }

    assert get_in(projected_activation, ["content", Access.at(0), "text"]) =~
             ~s(content_sha256="exact-logged-hash")
  end

  test "repairs a true orphaned skill_view before preserving its activation" do
    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "orphan-hash",
      "content" => "# Instructions survive orphan repair"
    }

    history = [
      Event.tool_call("s", "call_skill", "skill_view", %{"name" => "diagnose"}),
      Event.skill_activation("s", activation)
    ]

    assert {:ok, body} = Provider.request_body_preview(%{history: history})
    assert [call, synthetic_output, projected_activation] = body["input"]
    assert call["call_id"] == "call_skill"
    assert synthetic_output["call_id"] == "call_skill"

    assert %{"ok" => false, "error" => %{"kind" => "orphan_tool_call"}} =
             Jason.decode!(synthetic_output["output"])

    assert get_in(projected_activation, ["content", Access.at(0), "text"]) ==
             Pixir.Skills.render_activation(activation)
  end

  test "replays raw incident NDJSON seq 8 through 10 without inventing an orphan" do
    workspace = tmp_workspace()
    session_id = "raw-skill-incident"
    log_path = Pixir.Log.path(session_id, workspace: workspace)
    File.mkdir_p!(Path.dirname(log_path))

    raw_ndjson =
      ~S({"id":"e8","session_id":"raw-skill-incident","seq":8,"ts":"2026-07-05T00:00:08Z","type":"tool_call","data":{"call_id":"call_incident","name":"skill_view","args":{"name":"diagnose"}}}) <>
        "\n" <>
        ~S({"id":"e9","session_id":"raw-skill-incident","seq":9,"ts":"2026-07-05T00:00:09Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"incident-hash","content":"# Incident snapshot"}}) <>
        "\n" <>
        ~S({"id":"e10","session_id":"raw-skill-incident","seq":10,"ts":"2026-07-05T00:00:10Z","type":"tool_result","data":{"call_id":"call_incident","ok":true,"output":"# Incident snapshot","activated":true,"content_hash":"incident-hash"}}) <>
        "\n"

    try do
      File.write!(log_path, raw_ndjson)
      assert {:ok, history} = Pixir.Log.fold(session_id, workspace: workspace)
      assert Enum.map(history, & &1.seq) == [8, 9, 10]

      assert {:ok, body} =
               Provider.request_body_preview(%{history: history, workspace: workspace})

      assert [call, output, projected_activation] = body["input"]
      assert call["call_id"] == "call_incident"
      assert output["call_id"] == "call_incident"
      assert output["output"] == "# Incident snapshot"

      assert get_in(projected_activation, ["content", Access.at(0), "text"]) =~
               ~s(content_sha256="incident-hash")

      refute match?(
               {:ok, %{"error" => %{"kind" => "orphan_tool_call"}}},
               Jason.decode(output["output"])
             )
    after
      File.rm_rf!(workspace)
    end
  end

  test "pairs one matching skill_view while an unrelated call remains pending" do
    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "concurrent-hash",
      "content" => "# Concurrent activation"
    }

    raw_ndjson =
      ~S({"id":"e1","session_id":"raw-concurrent-skill","seq":1,"ts":"2026-07-05T00:00:01Z","type":"tool_call","data":{"call_id":"call_read","name":"read","args":{"path":"README.md"}}}) <>
        "\n" <>
        ~S({"id":"e2","session_id":"raw-concurrent-skill","seq":2,"ts":"2026-07-05T00:00:02Z","type":"tool_call","data":{"call_id":"call_skill","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e3","session_id":"raw-concurrent-skill","seq":3,"ts":"2026-07-05T00:00:03Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"concurrent-hash","content":"# Concurrent activation"}}) <>
        "\n" <>
        ~S({"id":"e4","session_id":"raw-concurrent-skill","seq":4,"ts":"2026-07-05T00:00:04Z","type":"tool_result","data":{"call_id":"call_read","ok":true,"output":"read body"}}) <>
        "\n" <>
        ~S({"id":"e5","session_id":"raw-concurrent-skill","seq":5,"ts":"2026-07-05T00:00:05Z","type":"tool_result","data":{"call_id":"call_skill","ok":true,"output":"skill body"}}) <>
        "\n"

    {history, workspace} = fold_raw_history!("raw-concurrent-skill", raw_ndjson)

    assert {:ok, body} =
             Provider.request_body_preview(%{history: history, workspace: workspace})

    assert [read_call, skill_call, read_result, skill_result, projected_activation] =
             body["input"]

    assert read_call["call_id"] == "call_read"
    assert skill_call["call_id"] == "call_skill"

    assert read_result == %{
             "type" => "function_call_output",
             "call_id" => "call_read",
             "output" => "read body"
           }

    assert skill_result == %{
             "type" => "function_call_output",
             "call_id" => "call_skill",
             "output" => "skill body"
           }

    assert get_in(projected_activation, ["content", Access.at(0), "text"]) ==
             Pixir.Skills.render_activation(activation)

    refute inspect(body["input"]) =~ "orphan_tool_call"
  end

  test "two matching skill_view calls remain ambiguous and use orphan repair" do
    activation = %{
      "name" => "diagnose",
      "source" => "repo",
      "scope" => "repo",
      "path" => "/skills/diagnose/SKILL.md",
      "content_hash" => "ambiguous-hash",
      "content" => "# Ambiguous activation"
    }

    raw_ndjson =
      ~S({"id":"e1","session_id":"raw-ambiguous-skill","seq":1,"ts":"2026-07-05T00:00:01Z","type":"tool_call","data":{"call_id":"call_skill_a","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e2","session_id":"raw-ambiguous-skill","seq":2,"ts":"2026-07-05T00:00:02Z","type":"tool_call","data":{"call_id":"call_skill_b","name":"skill_view","args":{"name":"diagnose","path":"SKILL.md"}}}) <>
        "\n" <>
        ~S({"id":"e3","session_id":"raw-ambiguous-skill","seq":3,"ts":"2026-07-05T00:00:03Z","type":"skill_activation","data":{"name":"diagnose","source":"repo","scope":"repo","path":"/skills/diagnose/SKILL.md","content_hash":"ambiguous-hash","content":"# Ambiguous activation"}}) <>
        "\n" <>
        ~S({"id":"e4","session_id":"raw-ambiguous-skill","seq":4,"ts":"2026-07-05T00:00:04Z","type":"tool_result","data":{"call_id":"call_skill_a","ok":true,"output":"skill a body"}}) <>
        "\n" <>
        ~S({"id":"e5","session_id":"raw-ambiguous-skill","seq":5,"ts":"2026-07-05T00:00:05Z","type":"tool_result","data":{"call_id":"call_skill_b","ok":true,"output":"skill b body"}}) <>
        "\n"

    {history, workspace} = fold_raw_history!("raw-ambiguous-skill", raw_ndjson)

    assert {:ok, body} =
             Provider.request_body_preview(%{history: history, workspace: workspace})

    assert [skill_call_a, skill_call_b, repair_a, repair_b, projected_activation] =
             body["input"]

    assert Enum.map([skill_call_a, skill_call_b], & &1["call_id"]) == [
             "call_skill_a",
             "call_skill_b"
           ]

    assert Enum.map([repair_a, repair_b], & &1["call_id"]) == [
             "call_skill_a",
             "call_skill_b"
           ]

    assert Enum.all?([repair_a, repair_b], fn output ->
             match?(
               %{"ok" => false, "error" => %{"kind" => "orphan_tool_call"}},
               Jason.decode!(output["output"])
             )
           end)

    assert get_in(projected_activation, ["content", Access.at(0), "text"]) ==
             Pixir.Skills.render_activation(activation)
  end

  test "folds compacted History as checkpoint plus recent tail", %{auth: auth} do
    history = [
      Event.user_message("s", "very old prompt") |> Event.with_seq(0),
      Event.assistant_message("s", "very old answer") |> Event.with_seq(1),
      Event.history_compaction("s", %{
        "range" => %{"from_seq" => 0, "to_seq" => 1},
        "source_event_count" => 2,
        "tail_event_count" => 1,
        "strategy" => "deterministic_operational_summary_v1",
        "summary" => "The user discussed an old task.",
        "files_touched" => [],
        "open_tasks" => ["user: continue carefully"],
        "limitations" => ["full Log remains authoritative"]
      })
      |> Event.with_seq(2),
      Event.user_message("s", "recent prompt") |> Event.with_seq(3)
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [checkpoint, recent] = Jason.decode!(body)["input"]
    assert [%{"text" => checkpoint_text}] = checkpoint["content"]
    assert checkpoint_text =~ "Compressed session memory"
    assert checkpoint_text =~ "The user discussed an old task."

    assert recent == %{
             "role" => "user",
             "content" => [%{"type" => "input_text", "text" => "recent prompt"}]
           }
  end

  test "a text_verbosity opt sets text.verbosity in the request body", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: []},
        auth: auth,
        text_verbosity: "low",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert Jason.decode!(body)["text"] == %{"verbosity" => "low"}
  end

  test "a reasoning_effort opt sets reasoning.effort in the request body", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: []},
        auth: auth,
        reasoning_effort: "high",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert Jason.decode!(body)["reasoning"] == %{"effort" => "high"}
  end

  test "puts prompt_cache_key in request body when provided", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: [], prompt_cache_key: "px1:test"},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert Jason.decode!(body)["prompt_cache_key"] == "px1:test"
  end

  test "request_body_preview adds Provider-hosted web_search and source include" do
    assert {:ok, body} =
             Provider.request_body_preview(%{
               history: [],
               model: "gpt-5.5",
               web_search: %{search_context_size: "low"}
             })

    assert %{"type" => "web_search", "search_context_size" => "low"} in body["tools"]
    assert "web_search_call.action.sources" in body["include"]
    assert body["store"] == false
    assert body["stream"] == true
  end

  test "request_body_preview preserves supported Provider-hosted web_search policy fields" do
    filters = %{"allowed_domains" => ["openai.com"]}
    user_location = %{"type" => "approximate", "country" => "US"}
    image_settings = %{"max_results" => 2}

    assert {:ok, body} =
             Provider.request_body_preview(%{
               history: [],
               web_search: %{
                 search_context_size: "medium",
                 filters: filters,
                 user_location: user_location,
                 external_web_access: false,
                 return_token_budget: "default",
                 search_content_types: ["text", "image"],
                 image_settings: image_settings
               }
             })

    assert tool = Enum.find(body["tools"], &(&1["type"] == "web_search"))
    assert tool["search_context_size"] == "medium"
    assert tool["filters"] == filters
    assert tool["user_location"] == user_location
    assert tool["external_web_access"] == false
    assert tool["return_token_budget"] == "default"
    assert tool["search_content_types"] == ["text", "image"]
    assert tool["image_settings"] == image_settings
  end

  test "request_body_preview does not duplicate raw and Pixir-owned web_search specs" do
    assert {:ok, body} =
             Provider.request_body_preview(%{
               history: [],
               hosted_tools: [
                 %{
                   "type" => "web_search",
                   "search_context_size" => "high",
                   "external_web_access" => false
                 }
               ],
               web_search: %{search_context_size: "low"}
             })

    assert [tool] = Enum.filter(body["tools"], &(&1["type"] == "web_search"))
    assert tool["search_context_size"] == "high"
    assert tool["external_web_access"] == false
  end

  test "request_body_preview honors include_sources false from web_search keyword config" do
    assert {:ok, body} =
             Provider.request_body_preview(%{
               history: [],
               web_search: [search_context_size: "low", include_sources: false]
             })

    assert %{"type" => "web_search", "search_context_size" => "low"} in body["tools"]
    refute "web_search_call.action.sources" in body["include"]
  end

  test "invalid Provider-hosted web_search config returns structured invalid_args" do
    assert {:error,
            %{
              kind: :invalid_args,
              message: message,
              details: %{"allowed" => ["low", "medium", "high"]}
            }} =
             Provider.request_body_preview(%{
               history: [],
               web_search: %{search_context_size: "planet-scale"}
             })

    assert is_binary(message)
  end

  test "Provider-hosted web_search rejects hostile shapes before body, Auth, or transport" do
    sentinel = "https://HOSTED_TOOLS_SECRET.example/?token=1"
    uri = URI.parse(sentinel)

    malformed = [
      uri,
      DateTime.utc_now(),
      MapSet.new([:invalid]),
      %{"filters" => uri},
      %{"filters" => %{"endpoint" => uri}},
      %{"filters" => MapSet.new([1])},
      %{"user_location" => %{"city" => DateTime.utc_now()}},
      %{"user_location" => %{"city" => [1 | :improper]}},
      %{"search_content_types" => ["text" | :improper]}
    ]

    for web_search <- malformed do
      assert {:error, %{kind: :invalid_args} = error} =
               Provider.request_body_preview(%{history: [], web_search: web_search})

      refute inspect(error) =~ sentinel
      assert {:ok, _json} = Jason.encode(error)
    end

    assert {:error, %{ok: false, error: %{kind: :invalid_args}} = error} =
             Provider.stream(
               %{history: [], web_search: %{"filters" => %{"endpoint" => uri}}},
               auth: :missing_hosted_tools_auth,
               transport: fn _request, _acc, _fun -> flunk("transport must not run") end
             )

    refute inspect(error) =~ sentinel
  end

  test "raw hosted_tools reject hostile values with bounded redacted errors" do
    sentinel = "https://RAW_HOSTED_TOOLS_SECRET.example/?token=1"
    uri = URI.parse(sentinel)

    malformed = [
      uri,
      [uri],
      [%{"type" => "web_search", "filters" => %{"endpoint" => uri}}],
      [%{"type" => "web_search"} | :improper]
    ]

    for hosted_tools <- malformed do
      assert {:error, %{kind: :invalid_args} = error} =
               Provider.request_body_preview(%{history: [], hosted_tools: hosted_tools})

      refute inspect(error) =~ sentinel
      assert {:ok, _json} = Jason.encode(error)
    end
  end

  test "hostile local body fields fail closed before Auth or transport" do
    sentinel = "https://LOCAL_BODY_SECRET.example/?token=1"
    uri = URI.parse(sentinel)

    malformed = [
      {:tools, [1 | :improper]},
      {:tools, [uri]},
      {:tools, [%{"parameters" => %{"required" => ["path" | :improper]}}]},
      {:system_prompt, uri},
      {:developer_context, uri},
      {:workspace, uri},
      {:output_schema, %{"name" => "result", "schema" => uri}},
      {:output_schema, %{"name" => "result", "schema" => %{"required" => ["value" | :improper]}}},
      {:prompt_cache_key, <<255>>},
      {:prompt_cache_retention, uri}
    ]

    for {field, value} <- malformed do
      request = Map.put(%{history: []}, field, value)

      assert {:error,
              %{
                kind: :invalid_args,
                details: %{"field" => error_field}
              } = preview_error} = Provider.request_body_preview(request, raw_config: %{})

      assert error_field == Atom.to_string(field)
      refute inspect(preview_error) =~ sentinel
      assert {:ok, _json} = Jason.encode(preview_error)

      assert {:error, %{ok: false, error: %{kind: :invalid_args}} = stream_error} =
               Provider.stream(request,
                 raw_config: %{},
                 max_retries: 0,
                 auth: :missing_local_body_auth,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )

      refute inspect(stream_error) =~ sentinel
      assert {:ok, _json} = Jason.encode(stream_error)
    end
  end

  test "local body field atom/string collisions fail closed" do
    values = %{
      system_prompt: "system",
      developer_context: "developer",
      workspace: File.cwd!(),
      tools: [],
      output_schema: %{},
      prompt_cache_key: "px:test",
      prompt_cache_retention: "in_memory"
    }

    for {field, value} <- values do
      request =
        %{history: []}
        |> Map.put(field, value)
        |> Map.put(Atom.to_string(field), value)

      assert {:error,
              %{
                kind: :invalid_args,
                details: %{
                  "field" => error_field,
                  "reason" => "normalized_key_collision"
                }
              }} = Provider.request_body_preview(request, raw_config: %{})

      assert error_field == Atom.to_string(field)
    end
  end

  test "valid local body fields preserve the Responses request shape" do
    tool = %{
      "type" => "function",
      "name" => "read",
      "description" => "Read a file",
      "parameters" => %{"type" => "object"}
    }

    output_schema = %{
      "name" => "result",
      "strict" => true,
      "schema" => %{"type" => "object", "required" => ["value"]}
    }

    assert {:ok, body} =
             Provider.request_body_preview(
               %{
                 history: [],
                 system_prompt: "system",
                 developer_context: "developer",
                 workspace: File.cwd!(),
                 tools: [tool],
                 output_schema: output_schema,
                 prompt_cache_key: "px:test"
               },
               raw_config: %{}
             )

    assert body["instructions"] == "system"
    assert [%{"role" => "developer"}] = body["input"]
    assert body["tools"] == [tool]
    assert body["text"]["format"]["schema"] == output_schema["schema"]
    assert body["prompt_cache_key"] == "px:test"
  end

  test "include_fields fails closed when include_sources config cannot normalize" do
    tools = [%{"type" => "web_search"}]

    for web_search <- [
          %{:include_sources => false, "include_sources" => false},
          [include_sources: false] ++ [:invalid]
        ] do
      assert {:error, %{kind: :invalid_args}} =
               Pixir.Provider.HostedTools.include_fields(%{"web_search" => web_search}, tools)
    end
  end

  test "request-level atom/string hosted-tool keys fail closed before body construction" do
    dual_web_search = %{
      "web_search" => %{"search_context_size" => "high"},
      history: [],
      web_search: false
    }

    dual_hosted_tools = %{
      "hosted_tools" => [%{"type" => "web_search"}],
      history: [],
      hosted_tools: []
    }

    for request <- [dual_web_search, dual_hosted_tools] do
      assert {:error,
              %{
                kind: :invalid_args,
                details: %{"reason" => "normalized_key_collision"}
              }} = Provider.request_body_preview(request)
    end

    assert {:error, %{kind: :invalid_args}} =
             Pixir.Provider.HostedTools.include_fields(dual_web_search, [
               %{"type" => "web_search"}
             ])
  end

  test "request-level atom/string model authority fails before body construction" do
    request = %{
      "model" => "claude-sonnet-5",
      history: [],
      model: "gpt-5.5"
    }

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :model, reason: :invalid_type}
              }
            }} = Provider.request_body_preview(request, raw_config: %{})
  end

  test "unsupported Provider-hosted web_search fields return structured invalid_args" do
    assert {:error,
            %{
              kind: :invalid_args,
              message: message,
              details: %{"reason" => "unsupported_fields", "supported" => supported}
            }} =
             Provider.request_body_preview(%{
               history: [],
               web_search: %{surprise_policy: true}
             })

    assert is_binary(message)
    assert "search_context_size" in supported
  end

  test "request_body_preview rejects non-map requests with structured invalid_args" do
    assert {:error,
            %{
              kind: :invalid_args,
              message: message,
              details: %{"expected" => "plain_map"}
            }} = Provider.request_body_preview("not a request")

    assert is_binary(message)
  end

  test "whole-document request structs fail closed across preview and stream" do
    sentinel = "https://WHOLE_REQUEST_SECRET.example/v1"

    for request <- [URI.parse(sentinel), DateTime.utc_now(), MapSet.new()] do
      assert {:error,
              %{kind: :invalid_args, details: %{"expected" => "plain_map"}} = preview_error} =
               Provider.request_body_preview(request)

      refute inspect(preview_error) =~ sentinel

      assert {:error,
              %{
                ok: false,
                error: %{kind: :invalid_args, details: %{expected: "plain_map"}}
              } = stream_error} =
               Provider.stream(request,
                 auth: :missing_whole_request_auth,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )

      refute inspect(stream_error) =~ sentinel
    end
  end

  test "hostile history fails closed before Auth, body, or transport" do
    base = Event.user_message("s", "base")

    malformed = [
      URI.parse("https://history.example"),
      [1 | :improper],
      [%{}],
      [%{type: :unknown_history_type, data: %{}}],
      [Map.put(Event.user_message("s", "hi"), :data, %{"value" => DateTime.utc_now()})],
      [
        %{
          base
          | type: :tool_call,
            data: %{
              "call_id" => "c1",
              "name" => "bash",
              "args" => %{"cmd" => ["echo" | "SECRET"]}
            }
        }
      ],
      [
        %{
          base
          | type: :reasoning,
            data: %{
              "item" => %{"id" => "rs_1", "payload" => [1 | nil]},
              "model" => "gpt-5.5",
              "dialect" => "openai"
            }
        }
      ]
    ]

    for history <- malformed do
      assert {:error,
              %{
                kind: :invalid_args,
                details: %{"field" => "history", "reason" => "invalid_event_list"}
              }} = Provider.request_body_preview(%{history: history})

      assert {:error, %{ok: false, error: %{kind: :invalid_args}}} =
               Provider.stream(%{history: history},
                 auth: :missing_history_auth,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )
    end
  end

  test "history request and event-envelope atom/string authority collisions fail closed" do
    request = %{
      "history" => [Event.user_message("string", "string")],
      history: [Event.user_message("atom", "atom")]
    }

    assert {:error,
            %{
              kind: :invalid_args,
              details: %{"field" => "history", "reason" => "normalized_key_collision"}
            }} = Provider.request_body_preview(request)

    sentinel = "HISTORY_ENVELOPE_SECRET"
    event = Event.user_message("event", "safe")

    for field <- [:type, :data, :seq, :session_id, :id, :ts] do
      history = [Map.put(event, Atom.to_string(field), sentinel)]

      assert {:error,
              %{
                kind: :invalid_args,
                details: %{"field" => "history", "reason" => "normalized_key_collision"}
              } = preview_error} = Provider.request_body_preview(%{history: history})

      refute inspect(preview_error) =~ sentinel

      assert {:error, %{ok: false, error: %{kind: :invalid_args}} = stream_error} =
               Provider.stream(%{history: history},
                 raw_config: %{},
                 auth: :missing_history_collision_auth,
                 transport: fn _request, _acc, _fun -> flunk("transport must not run") end
               )

      refute inspect(stream_error) =~ sentinel
    end
  end

  test "include_fields rejects whole-document request structs" do
    for request <- [URI.parse("https://include.example"), DateTime.utc_now(), MapSet.new()] do
      assert {:error, %{kind: :invalid_args}} =
               Pixir.Provider.HostedTools.include_fields(request, [
                 %{"type" => "web_search"}
               ])
    end
  end

  test "Provider-hosted web_search config rejects normalized key collisions" do
    assert {:error, %{kind: :invalid_args, message: message}} =
             Provider.request_body_preview(%{
               history: [],
               web_search: [{:search_context_size, "low"}, {"search_context_size", "high"}]
             })

    assert is_binary(message)
  end

  test "does not send prompt_cache_retention on ChatGPT/Codex backend", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: [], prompt_cache_retention: "24h"},
        auth: auth,
        base_url: "https://chatgpt.com/backend-api",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    refute Map.has_key?(Jason.decode!(body), "prompt_cache_retention")
  end

  test "a legacy URL cannot enable a backend-denied prompt_cache_retention extension", %{
    auth: auth
  } do
    {:ok, _} =
      Provider.stream(%{history: [], prompt_cache_retention: "24h"},
        auth: auth,
        base_url: "https://api.openai.test/v1/responses",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    refute Map.has_key?(Jason.decode!(body), "prompt_cache_retention")
  end

  test "an invalid reasoning_effort is dropped (model default)", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: []},
        auth: auth,
        reasoning_effort: "turbo",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    refute Map.has_key?(Jason.decode!(body), "reasoning")
  end

  test "no reasoning_effort omits reasoning entirely", %{auth: auth} do
    {:ok, _} =
      Provider.stream(%{history: []},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    refute Map.has_key?(Jason.decode!(body), "reasoning")
  end

  test "captures a reasoning item opaquely, in arrival order with calls (ADR 0007)", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.output_item.done",
        item: %{type: "reasoning", id: "rs_1", encrypted_content: "ENC", summary: []}
      }),
      sse(%{
        type: "response.output_item.done",
        item: %{type: "function_call", call_id: "call_1", name: "read", arguments: ~s({})}
      }),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, result} = Provider.stream(%{history: []}, auth: auth, transport: canned(chunks))
    assert result.finish_reason == :tool_calls

    # The whole item is kept verbatim (incl. encrypted_content), never decomposed.
    assert [%{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "ENC"}] =
             result.reasoning_items

    # Arrival order is preserved: reasoning then the call.
    assert [{:reasoning, %{"id" => "rs_1"}}, {:function_call, %{call_id: "call_1"}}] =
             result.output_items
  end

  test "replays a reasoning item verbatim when the model matches (ADR 0007)", %{auth: auth} do
    item = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "ENC"}
    history = [Event.user_message("s", "hi"), Event.reasoning("s", item, "gpt-test")]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        model: "gpt-test",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [_user, reasoning] = Jason.decode!(body)["input"]
    # Re-injected exactly as captured.
    assert reasoning == item
  end

  test "replays a skill activation snapshot into Responses input (ADR 0010)", %{auth: auth} do
    activation =
      Event.skill_activation("s", %{
        "name" => "sample",
        "description" => "Sample skill",
        "scope" => "repo",
        "source" => "repo",
        "path" => "/tmp/sample/SKILL.md",
        "content_hash" => "abc123",
        "content" => "# Sample skill\n\nUse this skill."
      })

    history = [activation, Event.user_message("s", "use it")]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [skill, user] = Jason.decode!(body)["input"]
    assert [%{"text" => text}] = skill["content"]
    assert text =~ ~s(<skill name="sample")
    assert text =~ ~s(content_sha256="abc123")
    assert text =~ "Use this skill."
    assert user["role"] == "user"
  end

  test "replays terminal subagent summaries without child logs (ADR 0011)", %{auth: auth} do
    history = [
      Event.subagent_event("s", %{
        "event" => "started",
        "subagent_id" => "sub_1",
        "agent" => "worker",
        "status" => "running",
        "summary" => nil
      }),
      Event.subagent_event("s", %{
        "event" => "finished",
        "subagent_id" => "sub_1",
        "agent" => "worker",
        "status" => "completed",
        "summary" => "Found the bug in auth.ex"
      })
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [summary] = Jason.decode!(body)["input"]
    assert [%{"text" => text}] = summary["content"]
    assert text == "Subagent sub_1 (worker) completed: Found the bug in auth.ex"
  end

  test "replays timed-out subagent summaries as model-visible context", %{auth: auth} do
    history = [
      Event.subagent_event("s", %{
        "event" => "timed_out",
        "subagent_id" => "sub_1",
        "child_session_id" => "child_1",
        "agent" => "explorer",
        "status" => "timed_out",
        "summary" => "Timed out after 52ms (configured timeout 50ms).",
        "timeout_ms" => 50,
        "elapsed_ms" => 52,
        "reason" => "timeout",
        "next_actions" => [
          "inspect_child_session_log",
          "retry_subagent_with_larger_timeout"
        ]
      })
    ]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    assert [summary] = Jason.decode!(body)["input"]
    assert [%{"text" => text}] = summary["content"]

    assert text ==
             "Subagent sub_1 (explorer) timed_out: Timed out after 52ms (configured timeout 50ms)."
  end

  test "drops a reasoning item captured under a different model (ADR 0007)", %{auth: auth} do
    item = %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "ENC"}
    history = [Event.user_message("s", "hi"), Event.reasoning("s", item, "gpt-OLD")]

    {:ok, _} =
      Provider.stream(%{history: history},
        auth: auth,
        model: "gpt-NEW",
        transport: canned([sse(%{type: "response.completed"})])
      )

    assert_received {:request, %{body: body}}
    # Only the user message survives; the foreign reasoning item is dropped, not 400'd.
    assert [%{"role" => "user"}] = Jason.decode!(body)["input"]
  end

  test "captures Provider-hosted web_search lifecycle, sources, and citations", %{auth: auth} do
    chunks = [
      sse(%{
        type: "response.web_search_call.searching",
        id: "ws_1",
        action: %{type: "search", query: "Pixir web search docs"}
      }),
      sse(%{
        type: "response.output_item.done",
        item: %{
          type: "web_search_call",
          id: "ws_1",
          status: "completed",
          action: %{
            type: "search",
            query: "Pixir web search docs",
            sources: [
              %{
                type: "url",
                title: "Web search",
                url: "https://platform.openai.com/docs/guides/tools-web-search"
              }
            ]
          }
        }
      }),
      sse(%{type: "response.output_text.delta", delta: "WEB_SEARCH_SMOKE_OK"}),
      sse(%{
        type: "response.output_item.done",
        item: %{
          type: "message",
          content: [
            %{
              type: "output_text",
              text: "WEB_SEARCH_SMOKE_OK",
              annotations: [
                %{
                  type: "url_citation",
                  title: "Web search",
                  url: "https://platform.openai.com/docs/guides/tools-web-search",
                  start_index: 0,
                  end_index: 19
                }
              ]
            }
          ]
        }
      }),
      sse(%{type: "response.completed"})
    ]

    assert {:ok, result} =
             Provider.stream(%{history: [], web_search: true},
               auth: auth,
               transport: canned(chunks)
             )

    assert result.text == "WEB_SEARCH_SMOKE_OK"
    assert result.finish_reason == :stop

    assert %{
             "web_search" => %{
               "call_count" => 1,
               "annotation_count" => 1,
               "source_count" => 1,
               "events" => [
                 %{
                   "type" => "response.web_search_call.searching",
                   "action" => event_action
                 }
               ],
               "calls" => [
                 %{"type" => "web_search_call", "id" => "ws_1", "action" => call_action}
               ],
               "annotations" => [
                 %{
                   "type" => "url_citation",
                   "url" => "https://platform.openai.com/docs/guides/tools-web-search"
                 }
               ],
               "sources" => [
                 %{
                   "url" => "https://platform.openai.com/docs/guides/tools-web-search",
                   "title" => "Web search"
                 }
               ]
             }
           } = result.provider_hosted_tools

    assert event_action["query_present"] == true
    assert event_action["query_length"] == 21
    refute Map.has_key?(event_action, "query")
    assert call_action["query_present"] == true
    assert call_action["query_length"] == 21
    refute Map.has_key?(call_action, "query")

    assert [{:provider_hosted_tool, %{"type" => "web_search_call", "id" => "ws_1"}}] =
             result.output_items
  end

  test "non-2xx status becomes a structured provider_http_error", %{auth: auth} do
    transport = canned(["{\"error\":\"unauthorized\"}"], 401)

    assert {:error, %{error: %{kind: :provider_http_error, details: %{status: 401}}}} =
             Provider.stream(%{history: []}, auth: auth, transport: transport)
  end

  test "transport errors with an accumulator become structured network errors", %{auth: auth} do
    transport = fn _request, acc, _fun ->
      {:error, %Finch.TransportError{reason: :timeout}, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :network,
                message: "provider stream failed",
                details: %{reason: reason, status: nil}
              }
            }} = Provider.stream(%{history: []}, auth: auth, transport: transport, max_retries: 0)

    assert reason == :timeout
  end

  test "transport crashes cannot echo request credentials through errors or logs" do
    sentinel = "SECRET_SENTINEL_319_FUNCTION_CLAUSE"
    {:ok, auth} = RotatingHeaderAuth.start_link([sentinel])

    transport = fn %{headers: [{"never-matches", _value}]}, acc, _fun -> {:ok, acc} end

    parent = self()

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        send(
          parent,
          {:transport_crash_result,
           Provider.stream(%{history: []},
             auth: auth,
             transport: transport,
             max_retries: 0
           )}
        )
      end)

    assert_receive {:transport_crash_result,
                    {:error,
                     %{
                       error: %{
                         kind: :network,
                         details: %{reason: :function_clause, transport: "http_sse"}
                       }
                     } = error}}

    refute inspect(error) =~ sentinel
    refute logs =~ sentinel
  end

  test "disabled idle watchdogs still contain transport crashes and credentials" do
    for timeout <- [0, :infinity] do
      sentinel = "SECRET_SENTINEL_319_DISABLED_WATCHDOG_#{timeout}"
      {:ok, auth} = RotatingHeaderAuth.start_link([sentinel])

      transport = fn %{headers: [{"never-matches", _value}]}, acc, _fun -> {:ok, acc} end
      parent = self()

      logs =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            parent,
            {:disabled_watchdog_result, timeout,
             Provider.stream(%{history: []},
               auth: auth,
               transport: transport,
               stream_idle_timeout_ms: timeout,
               max_retries: 0
             )}
          )
        end)

      assert_receive {:disabled_watchdog_result, ^timeout,
                      {:error,
                       %{
                         error: %{
                           kind: :network,
                           details: %{reason: :function_clause, transport: "http_sse"}
                         }
                       } = error}}

      refute inspect(error) =~ sentinel
      refute logs =~ sentinel
    end
  end

  test "non-structured transport failures cannot echo the authenticated request" do
    sentinel = "SECRET_SENTINEL_319_RETURNED_ERROR"
    {:ok, auth} = RotatingHeaderAuth.start_link([sentinel])

    transport = fn request, acc, _fun -> {:error, {:echo, request}, acc} end

    assert {:error,
            %{
              error: %{
                kind: :network,
                details: %{reason: :transport_failure, status: nil}
              }
            } = error} =
             Provider.stream(%{history: []}, auth: auth, transport: transport, max_retries: 0)

    refute inspect(error) =~ sentinel
  end

  test "structured transport failures cannot echo the authenticated request" do
    sentinel = "SECRET_SENTINEL_319_STRUCTURED_ERROR"
    {:ok, auth} = RotatingHeaderAuth.start_link([sentinel])
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    transport = fn request, acc, _fun ->
      Agent.update(attempts, &(&1 + 1))

      error =
        Pixir.Tool.error(:provider_http_error, "transport echoed #{sentinel}", %{
          request: request
        })

      {:error, error, acc}
    end

    assert {:error,
            %{
              error: %{
                kind: :provider_http_error,
                message: "Provider transport returned an error.",
                details: %{}
              }
            } = error} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: transport,
               max_retries: 2,
               sleep: fn _ -> :ok end
             )

    refute inspect(error) =~ sentinel
    assert Agent.get(attempts, & &1) == 1
  end

  test "probe returns the model when the backend accepts the request", %{auth: auth} do
    transport = canned([sse(%{type: "response.completed"})])

    assert {:ok, %{model: "gpt-5-codex"}} =
             Provider.probe(auth: auth, transport: transport, model: "gpt-5-codex")
  end

  test "probe surfaces a structured error for a rejected model id", %{auth: auth} do
    transport = canned(["{\"error\":\"unknown model\"}"], 404)

    assert {:error, %{error: %{kind: :provider_http_error, details: %{status: 404}}}} =
             Provider.probe(auth: auth, transport: transport, model: "bogus-model")
  end

  test "classifies a 429 usage-limit body with a friendly message and reset time", %{auth: auth} do
    body =
      ~s({"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","plan_type":"pro","resets_in_seconds":3600}})

    assert {:error, %{error: %{kind: :usage_limit_reached, message: message, details: details}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 429))

    assert message =~ "usage limit"
    assert message =~ "pro plan"
    assert message =~ "~60 min"
    assert details.resets_in_seconds == 3600
  end

  test "classifies an unsupported-model 400 (detail body) as model_not_supported", %{auth: auth} do
    body =
      ~s({"detail":"The 'gpt-5-codex' model is not supported when using Codex with a ChatGPT account."})

    assert {:error, %{error: %{kind: :model_not_supported, message: message}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 400))

    assert message =~ "not supported"
  end

  test "classifies a context_length_exceeded 400 (error code) as :context_overflow", %{
    auth: auth
  } do
    body =
      ~s({"error":{"code":"context_length_exceeded","message":"This model's maximum context length is 272000 tokens. However, your messages resulted in 281544 tokens."}})

    assert {:error, %{error: %{kind: :context_overflow, message: message, details: details}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 400))

    assert message =~ "maximum context length"
    assert details.status == 400
    assert details.code == "context_length_exceeded"
  end

  test "classifies a context_length_exceeded 400 by code even with generic type and message",
       %{auth: auth} do
    body =
      ~s({"error":{"type":"invalid_request_error","code":"context_length_exceeded","message":"Bad request."}})

    assert {:error, %{error: %{kind: :context_overflow, details: details}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 400))

    assert details.status == 400
    assert details.type == "invalid_request_error"
    assert details.code == "context_length_exceeded"
  end

  test "classifies a context-window 400 by message shape as :context_overflow", %{auth: auth} do
    body =
      ~s({"error":{"type":"invalid_request_error","message":"Your input exceeds the context window of this model."}})

    assert {:error, %{error: %{kind: :context_overflow, details: %{status: 400}}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 400))
  end

  test "classifies a 413 prompt-too-long body as :context_overflow", %{auth: auth} do
    body = ~s({"error":{"type":"invalid_request_error","message":"Prompt is too long."}})

    assert {:error, %{error: %{kind: :context_overflow, details: %{status: 413}}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 413))
  end

  test "an unrelated 400 still classifies as the generic provider_http_error", %{auth: auth} do
    body = ~s({"error":{"type":"invalid_request_error","message":"Unknown parameter: blorp."}})

    assert {:error, %{error: %{kind: :provider_http_error, details: %{status: 400}}}} =
             Provider.stream(%{history: []}, auth: auth, transport: canned([body], 400))
  end

  test "classifies a plain 429 (no usage type) as transient :rate_limited", %{auth: auth} do
    assert {:error, %{error: %{kind: :rate_limited}}} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: canned(["{}"], 429),
               max_retries: 0
             )
  end

  # A transport that fails the first N attempts (with `status`), then succeeds.
  defp flaky(fail_times, status) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fun = fn _req, acc, feed ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n < fail_times do
        acc = feed.({:status, status}, acc)
        {:ok, feed.({:data, "{}"}, acc)}
      else
        acc = feed.({:status, 200}, acc)

        {:ok,
         feed.({:data, "data: " <> Jason.encode!(%{type: "response.completed"}) <> "\n\n"}, acc)}
      end
    end

    {fun, counter}
  end

  describe "retry/backoff" do
    test "retries a 503 then succeeds", %{auth: auth} do
      {transport, counter} = flaky(1, 503)

      assert {:ok, _} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: transport,
                 sleep: fn _ -> :ok end,
                 max_retries: 2
               )

      assert Agent.get(counter, & &1) == 2
    end

    test "does not retry a terminal usage limit", %{auth: auth} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      body = ~s({"error":{"type":"usage_limit_reached","message":"x"}})

      transport = fn _req, acc, feed ->
        Agent.update(counter, &(&1 + 1))
        acc = feed.({:status, 429}, acc)
        {:ok, feed.({:data, body}, acc)}
      end

      assert {:error, %{error: %{kind: :usage_limit_reached}}} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: transport,
                 sleep: fn _ -> :ok end,
                 max_retries: 3
               )

      assert Agent.get(counter, & &1) == 1
    end

    test "gives up after max_retries", %{auth: auth} do
      {transport, counter} = flaky(10, 503)

      assert {:error, %{error: %{kind: :provider_http_error}}} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: transport,
                 sleep: fn _ -> :ok end,
                 max_retries: 2
               )

      # initial attempt + 2 retries
      assert Agent.get(counter, & &1) == 3
    end
  end

  describe "stream idle timeout" do
    defp hanging(chunks \\ []) do
      fn _http_request, acc, fun ->
        acc = fun.({:status, 200}, acc)
        acc = Enum.reduce(chunks, acc, fn chunk, a -> fun.({:data, chunk}, a) end)
        :timer.sleep(:infinity)
        {:ok, acc}
      end
    end

    test "cuts a hung HTTP/SSE stream with a structured error", %{auth: auth} do
      chunks = [sse(%{type: "response.output_text.delta", delta: "partial"})]

      assert {:error,
              %{
                ok: false,
                error: %{
                  kind: :stream_idle_timeout,
                  message: message,
                  details: %{
                    timeout_ms: 25,
                    transport: "http_sse",
                    next_actions: next_actions
                  }
                }
              }} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: hanging(chunks),
                 stream_idle_timeout_ms: 25,
                 max_retries: 2,
                 sleep: fn _ -> :ok end
               )

      assert message =~ "stalled"
      assert "retry_turn" in next_actions
    end

    test "does not retry a stream idle timeout", %{auth: auth} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      transport = fn req, acc, fun ->
        Agent.update(counter, &(&1 + 1))
        hanging().(req, acc, fun)
      end

      assert {:error, %{error: %{kind: :stream_idle_timeout}}} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: transport,
                 stream_idle_timeout_ms: 25,
                 max_retries: 2,
                 sleep: fn _ -> :ok end
               )

      assert Agent.get(counter, & &1) == 1
    end

    test "leaves a completing stream unchanged", %{auth: auth} do
      chunks = [
        sse(%{type: "response.output_text.delta", delta: "ok"}),
        sse(%{type: "response.completed"})
      ]

      assert {:ok, %{text: "ok"}} =
               Provider.stream(%{history: []},
                 auth: auth,
                 transport: canned(chunks),
                 stream_idle_timeout_ms: 50
               )
    end
  end

  test "propagates a not-authenticated error before streaming" do
    name = :"auth_#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "pixir-prov-noauth-#{System.unique_integer([:positive])}.json")

    {:ok, _} = Auth.start_link(name: name, store_path: path, env_api_key: nil, oauth: NoOAuth)

    assert {:error, %{error: %{kind: :not_authenticated}}} =
             Provider.stream(%{history: []}, auth: name, transport: canned([]))
  end

  test "blank overrides never become the Provider or catalog default" do
    home =
      Path.join(
        System.tmp_dir!(),
        "pixir-provider-blank-model-#{System.unique_integer([:positive])}"
      )

    prior_home = System.get_env("PIXIR_HOME")
    prior_env = System.get_env("PIXIR_MODEL")
    prior_app = Application.get_env(:pixir, :model)
    File.mkdir_p!(home)
    System.put_env("PIXIR_HOME", home)
    System.put_env("PIXIR_MODEL", "   ")
    Application.put_env(:pixir, :model, "")

    on_exit(fn ->
      if prior_home,
        do: System.put_env("PIXIR_HOME", prior_home),
        else: System.delete_env("PIXIR_HOME")

      if prior_env,
        do: System.put_env("PIXIR_MODEL", prior_env),
        else: System.delete_env("PIXIR_MODEL")

      if prior_app,
        do: Application.put_env(:pixir, :model, prior_app),
        else: Application.delete_env(:pixir, :model)

      File.rm_rf!(home)
    end)

    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"model" => " file-model "}))
    assert Provider.default_model() == "file-model"

    models = Provider.models()
    assert Enum.count(models, & &1["default"]) == 1
    assert Enum.find(models, & &1["default"])["id"] == "file-model"
    refute Enum.any?(models, &(&1["id"] in ["", "   "]))

    File.write!(Path.join(home, "config.json"), Jason.encode!(%{"model" => "   "}))
    assert Provider.default_model() == "gpt-5.5"
    assert Enum.find(Provider.models(), & &1["default"])["id"] == "gpt-5.5"
  end

  test "malformed profiles fail before body, Auth, or transport" do
    sentinel = "https://stage.example/v1/responses"

    profiles = [{%{"mode" => "future", "responses_url" => sentinel}, :invalid_config}]

    for {profile, kind} <- profiles do
      opts = [
        raw_config: %{"model" => "gpt-5.4-mini", "responses_backend" => profile},
        auth: :missing_issue_317_auth_process,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end,
        max_retries: 0
      ]

      assert {:error,
              %{
                ok: false,
                error: %{kind: ^kind, details: %{field: field, reason: reason}}
              } = payload} = Provider.stream(%{history: []}, opts)

      assert field in [:mode, :responses_backend]
      assert reason == :unknown_mode
      refute inspect(payload) =~ sentinel

      assert {:error, %{error: %{kind: ^kind}}} =
               Provider.request_body_preview(%{history: []}, opts)
    end
  end

  test "default routing preserves exact ChatGPT body bytes and ordered auth headers", %{
    auth: auth
  } do
    subscription_headers = [
      {"authorization", "Bearer subscription-token"},
      {"chatgpt-account-id", "account-id"}
    ]

    {:ok, subscription_auth} = StaticHeaderAuth.start_link(subscription_headers)

    for {auth_source, auth_headers} <- [
          {auth, [{"authorization", "Bearer sk-test"}]},
          {subscription_auth, subscription_headers}
        ] do
      assert {:ok, _result} =
               Provider.stream(%{history: []},
                 raw_config: %{},
                 auth: auth_source,
                 transport: canned([sse(%{type: "response.completed"})])
               )

      assert_received {:request, request}

      assert request.url == "https://chatgpt.com/backend-api/codex/responses"
      assert request.body == @default_body_golden

      assert request.headers ==
               [
                 {"content-type", "application/json"},
                 {"accept", "text/event-stream"},
                 {"openai-beta", "responses=experimental"},
                 {"originator", "pixir"}
               ] ++ auth_headers
    end
  end

  test "routing preflight rejects an incompatible injected WebSocket seam before body or Auth" do
    transport = fn _request, _acc, _fun -> flunk("transport must not run") end

    assert {:error,
            %{
              error: %{
                kind: :invalid_args,
                details: %{field: :transport, reason: :incompatible_transport_seam}
              }
            }} =
             Provider.stream(%{history: []},
               responses_backend: %{"mode" => "chatgpt_codex"},
               provider_transport: :websocket,
               auth: :must_not_be_called,
               transport: transport
             )

    refute_received {:request, _request}
  end

  test "request_body_preview applies explicit routing validation without resolving Auth" do
    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{field: :provider_transport, reason: :invalid_transport}
              }
            }} =
             Provider.request_body_preview(%{history: []},
               responses_backend: %{"mode" => "chatgpt_codex"},
               provider_transport: :future,
               auth: :must_not_be_called
             )
  end

  test "outer retries resolve fresh auth while reusing the frozen route" do
    {:ok, auth} = RotatingHeaderAuth.start_link(["first-token", "second-token"])

    transport =
      canned_attempts([
        {["{}"], 503},
        {[sse(%{type: "response.completed"})], 200}
      ])

    assert {:ok, _result} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: transport,
               sleep: fn _ -> :ok end,
               max_retries: 1
             )

    assert_received {:request, first_request}
    assert_received {:request, second_request}

    assert first_request.url == second_request.url

    assert List.keyfind(first_request.headers, "authorization", 0) ==
             {"authorization", "Bearer first-token"}

    assert List.keyfind(second_request.headers, "authorization", 0) ==
             {"authorization", "Bearer second-token"}
  end

  test "struct-shaped profiles fail closed before preview body construction" do
    sentinel = "https://SECRET.example/v1/responses"

    for profile <- [URI.parse(sentinel), DateTime.utc_now(), MapSet.new([:invalid])] do
      assert {:error, %{error: %{kind: :invalid_config}} = payload} =
               Provider.request_body_preview(%{history: []}, responses_backend: profile)

      refute inspect(payload) =~ sentinel
    end
  end

  test "improper-list Config values do not escape the canonical preview barrier" do
    assert {:ok, body} =
             Provider.request_body_preview(%{history: []},
               raw_config: %{
                 "web_search" => [{"enabled", true} | :secret_tail],
                 "models" => ["gpt-5.5" | :secret_tail]
               }
             )

    assert body["model"] == "gpt-5.5"
    refute Map.has_key?(body, "tools")
  end

  test "request_body_preview resolves the Config model once when request omits it" do
    assert {:ok, body} =
             Provider.request_body_preview(%{history: []},
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert body["model"] == "gpt-5.4-mini"
  end

  test "direct preview applies snapshotted reasoning and text defaults with caller precedence" do
    raw = %{
      "reasoning" => %{"effort" => "low"},
      "text" => %{"verbosity" => "high"}
    }

    assert {:ok, configured} =
             Provider.request_body_preview(%{history: []}, raw_config: raw)

    assert configured["reasoning"] == %{"effort" => "low"}
    assert configured["text"] == %{"verbosity" => "high"}

    assert {:ok, overridden} =
             Provider.request_body_preview(%{history: []},
               raw_config: raw,
               reasoning_effort: "xhigh",
               text_verbosity: "medium"
             )

    assert overridden["reasoning"] == %{"effort" => "xhigh"}
    assert overridden["text"] == %{"verbosity" => "medium"}
  end

  test "Config ingress seams are consumed before runtime for new and reused resolutions", %{
    auth: auth
  } do
    alias Pixir.Provider.StreamIdle

    Code.ensure_loaded!(StreamIdle)
    traced = self()

    tracer =
      spawn_link(fn ->
        forward_traces(traced)
      end)

    :erlang.trace(traced, true, [:call, {:tracer, tracer}])
    assert :erlang.trace_pattern({StreamIdle, :run, 3}, true, []) == 1

    on_exit(fn ->
      :erlang.trace_pattern({StreamIdle, :run, 3}, false, [])
      Process.exit(tracer, :kill)
    end)

    loader = fn _opts ->
      {:ok,
       %{
         present?: true,
         origin: :programmatic,
         document: %{"model" => "gpt-5.4-mini"}
       }}
    end

    transport = canned([sse(%{type: "response.completed"})])

    assert {:ok, _result} =
             Provider.stream(%{history: []},
               auth: auth,
               transport: transport,
               config_path: "/tmp/config-seam-sentinel",
               request_snapshot_loader: loader
             )

    assert_receive {:captured_trace,
                    {:trace, _pid, :call, {StreamIdle, :run, [_stream_fn, runtime_opts, _label]}}}

    refute Enum.any?(
             [:config_path, :raw_config, :request_snapshot_loader],
             &Keyword.has_key?(runtime_opts, &1)
           )

    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{"model" => "gpt-5.4-mini"}
             )

    assert {:ok, _result} =
             Provider.stream(%{history: []},
               resolved_provider_request: resolved,
               auth: auth,
               transport: transport,
               config_path: "/tmp/reused-config-seam-sentinel",
               raw_config: %{"model" => "must-not-survive"},
               request_snapshot_loader: fn _ ->
                 flunk("reused resolution must not reload Config")
               end
             )

    assert_receive {:captured_trace,
                    {:trace, _pid, :call, {StreamIdle, :run, [_stream_fn, runtime_opts, _label]}}}

    refute Enum.any?(
             [:config_path, :raw_config, :request_snapshot_loader],
             &Keyword.has_key?(runtime_opts, &1)
           )
  end

  defp forward_traces(test) do
    receive do
      message ->
        send(test, {:captured_trace, message})
        forward_traces(test)
    end
  end

  test "Provider rejects a pre-resolved Anthropic identity before body construction" do
    assert {:ok, anthropic} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: :auto, request: %{}, provider_opts: []},
               raw_config: %{"model" => "claude-fable-5"}
             )

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{
                  field: :resolved_provider_request,
                  reason: :invalid_resolved_request
                }
              }
            }} =
             Provider.request_body_preview(%{history: []},
               resolved_provider_request: anthropic
             )
  end

  test "Provider rejects a fabricated resolved value with an invalid model" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    fabricated = struct(resolved, model: "")

    assert {:error,
            %{error: %{kind: :invalid_config, details: %{reason: :invalid_resolved_request}}}} =
             Provider.request_body_preview(%{history: []},
               resolved_provider_request: fabricated
             )
  end

  test "Provider rejects and redacts invalid UTF-8 models before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    invalid = <<255>>
    fabricated = struct(resolved, model: invalid)
    projection = inspect(fabricated)
    refute projection =~ inspect(invalid)
    refute projection =~ "Inspect.Error"

    opts = [
      resolved_provider_request: fabricated,
      auth: :missing_utf8_model_auth,
      transport: fn _request, _acc, _fun -> flunk("transport must not run") end
    ]

    assert {:error, %{error: %{kind: :invalid_config}}} =
             Provider.request_body_preview(%{history: []}, opts)

    assert {:error, %{error: %{kind: :invalid_config}}} =
             Provider.stream(%{history: []}, opts)

    assert {:ok, unicode_body} =
             Provider.request_body_preview(%{history: [], model: "modelo-ñ"}, raw_config: %{})

    assert unicode_body["model"] == "modelo-ñ"
  end

  test "Provider rejects fabricated private defaults before attaching them" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    fabricated = struct(resolved, provider_defaults: %{})

    assert {:error,
            %{
              error: %{
                kind: :invalid_config,
                details: %{
                  field: :resolved_provider_request,
                  reason: :invalid_resolved_request
                }
              }
            }} =
             Provider.request_body_preview(%{history: []},
               resolved_provider_request: fabricated
             )
  end

  test "Provider rejects unsafe web_search defaults before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    defaults = Map.fetch!(Map.from_struct(resolved), :provider_defaults)
    sentinel = "WEB_SEARCH_DEFAULTS_SECRET"
    invalid_utf8 = <<255>>

    malformed = [
      %{"unknown" => sentinel},
      %{"filters" => %{"callback" => fn -> sentinel end}},
      %{"filters" => %{"ids" => {:secret, sentinel}}},
      %{"user_location" => [sentinel]},
      %{"search_content_types" => ["text" | {:secret, sentinel}]},
      %{"filters" => %{invalid_utf8 => "value"}},
      %{"filters" => %{"id" => invalid_utf8}},
      %{"filters" => Date.utc_today()}
    ]

    for web_search <- malformed do
      fabricated = struct(resolved, provider_defaults: %{defaults | web_search: web_search})
      refute Pixir.Providers.ResolvedProviderRequest.provider_defaults_valid?(fabricated)
      refute inspect(fabricated) =~ sentinel

      opts = [
        resolved_provider_request: fabricated,
        auth: :missing_web_search_defaults_auth,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end
      ]

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :resolved_provider_request,
                    reason: :invalid_resolved_request
                  }
                }
              }} = Provider.request_body_preview(%{history: []}, opts)

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Provider.stream(%{history: []}, opts)
    end
  end

  test "Provider rejects fabricated Responses capabilities before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    capabilities = Pixir.Providers.ResolvedProviderRequest.capabilities(resolved)

    sentinel = "CAPABILITIES_SECRET"

    malformed = [
      struct(resolved, capabilities: %{}),
      struct(resolved, capabilities: %{capabilities | tool_dialect: :anthropic}),
      struct(resolved, capabilities: %{capabilities | prompt_cache: :cache_control}),
      struct(resolved, capabilities: %{secret: sentinel})
    ]

    for fabricated <- malformed do
      refute inspect(fabricated) =~ sentinel

      opts = [
        resolved_provider_request: fabricated,
        auth: :missing_capabilities_auth,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end
      ]

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :resolved_provider_request,
                    reason: :invalid_resolved_request
                  }
                }
              }} = Provider.request_body_preview(%{history: []}, opts)

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Provider.stream(%{history: []}, opts)
    end
  end

  test "Provider rejects and redacts fabricated source evidence before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    sentinel = "SOURCE_EVIDENCE_SECRET"

    malformed = [
      %{
        provider: :direct,
        model: :default,
        responses_backend: :absent,
        extra: sentinel
      },
      %{provider: sentinel, model: :default, responses_backend: :absent},
      %{provider: :direct, model: sentinel, responses_backend: :absent},
      %{provider: :direct, model: :default, responses_backend: sentinel}
    ]

    for source_evidence <- malformed do
      fabricated = struct(resolved, source_evidence: source_evidence)
      refute inspect(fabricated) =~ sentinel

      opts = [
        resolved_provider_request: fabricated,
        auth: :missing_source_evidence_auth,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end
      ]

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :resolved_provider_request,
                    reason: :invalid_resolved_request
                  }
                }
              }} = Provider.request_body_preview(%{history: []}, opts)

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Provider.stream(%{history: []}, opts)
    end
  end

  test "Provider rejects and redacts fabricated backend values before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    sentinel = "BACKEND_SENTINEL"
    default_backend = Pixir.Providers.ResponsesBackend.default()

    malformed = [
      %{token: sentinel},
      struct(default_backend, auth_policy: {:bearer_env, sentinel})
    ]

    for backend <- malformed do
      fabricated = struct(resolved, responses_backend: backend)
      projection = inspect(fabricated)
      refute projection =~ sentinel
      refute projection =~ "provider_defaults"
      refute projection =~ "Inspect.Error"

      opts = [
        resolved_provider_request: fabricated,
        auth: :missing_backend_auth,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end
      ]

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :resolved_provider_request,
                    reason: :invalid_resolved_request
                  }
                }
              }} = Provider.request_body_preview(%{history: []}, opts)

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Provider.stream(%{history: []}, opts)
    end
  end

  test "Provider rejects and redacts fabricated identity values before body or Auth" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    sentinel = "IDENTITY_SENTINEL"

    malformed = [
      struct(resolved, provider: sentinel),
      struct(resolved, model: %{secret: sentinel}),
      struct(resolved, dialect: sentinel)
    ]

    for fabricated <- malformed do
      projection = inspect(fabricated)
      refute projection =~ sentinel
      refute projection =~ "provider_defaults"
      refute projection =~ "Inspect.Error"

      opts = [
        resolved_provider_request: fabricated,
        auth: :missing_identity_auth,
        transport: fn _request, _acc, _fun -> flunk("transport must not run") end
      ]

      assert {:error,
              %{
                error: %{
                  kind: :invalid_config,
                  details: %{
                    field: :resolved_provider_request,
                    reason: :invalid_resolved_request
                  }
                }
              }} = Provider.request_body_preview(%{history: []}, opts)

      assert {:error, %{error: %{kind: :invalid_config}}} =
               Provider.stream(%{history: []}, opts)
    end
  end

  test "Inspect never loads a fabricated Provider module or runs its on_load callback" do
    assert {:ok, resolved} =
             Pixir.Providers.Registry.resolve_request(
               %{provider_intent: {:direct, Provider}, request: %{}, provider_opts: []},
               raw_config: %{}
             )

    unloaded = UnloadedInspectProvider
    marker = {unloaded, :loaded}
    :persistent_term.erase(marker)
    :code.purge(unloaded)
    :code.delete(unloaded)

    on_exit(fn ->
      :persistent_term.erase(marker)
    end)

    refute Code.loaded?(unloaded)
    fabricated = struct(resolved, provider: unloaded)
    projection = inspect(fabricated)

    refute projection =~ "UnloadedInspectProvider"
    refute projection =~ "Inspect.Error"
    refute Code.loaded?(unloaded)
    assert :persistent_term.get(marker, :absent) == :absent

    opts = [
      resolved_provider_request: fabricated,
      auth: :missing_unloaded_provider_auth,
      transport: fn _request, _acc, _fun -> flunk("transport must not run") end
    ]

    assert {:error, %{error: %{kind: :invalid_config}}} =
             Provider.request_body_preview(%{history: []}, opts)

    assert {:error, %{error: %{kind: :invalid_config}}} =
             Provider.stream(%{history: []}, opts)
  end

  test "probe reports the snapshotted model after transport mutates global Config", %{auth: auth} do
    prior_model = Application.get_env(:pixir, :model)

    on_exit(fn ->
      if prior_model,
        do: Application.put_env(:pixir, :model, prior_model),
        else: Application.delete_env(:pixir, :model)
    end)

    transport = fn _request, acc, fun ->
      Application.put_env(:pixir, :model, "gpt-mutated")
      acc = fun.({:status, 200}, acc)
      acc = fun.({:data, sse(%{type: "response.completed"})}, acc)
      {:ok, acc}
    end

    assert {:ok, %{model: "gpt-5.4-mini"}} =
             Provider.probe(
               raw_config: %{"model" => "gpt-5.4-mini"},
               auth: auth,
               transport: transport,
               max_retries: 0
             )
  end
end
