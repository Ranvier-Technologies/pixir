defmodule Mix.Tasks.Pixir.Smoke.Websocket do
  @shortdoc "Opt-in WebSocket smoke for Codex Responses continuation"

  @moduledoc """
  Runs a bounded real-network smoke against the Responses WebSocket transport.

  This validates the Codex-first subscription path as an opt-in smoke for the
  production Provider transport. It intentionally avoids printing tokens, account ids,
  or full response ids.

  Usage:

      mix pixir.smoke.websocket --dry-run --json
      mix pixir.smoke.websocket --json
      mix pixir.smoke.websocket --model gpt-5.5 --reasoning-effort low --json
      mix pixir.smoke.websocket --probe-cache-routing --json
      mix pixir.smoke.websocket --endpoint wss://chatgpt.com/backend-api/codex/responses --json
      mix pixir.smoke.websocket --help

  Checks:

    * WebSocket handshake returns `101 Switching Protocols`.
    * Minimal `response.create` replies with `ok`.
    * Same-socket `previous_response_id` continuation replies with `ok2`.
    * A tool-call loop can continue with `function_call_output`.
    * A new socket cannot continue a `store: false` response from an old socket.

  Options:

    * `--model MODEL` - model to probe. Default: `gpt-5.5`.
    * `--reasoning-effort EFFORT` - low/medium/high/xhigh. Default: `low`.
    * `--endpoint URL` - `wss://...` endpoint. Default: auto from credential kind.
    * `--timeout-ms N` - per response timeout. Default: 30000.
    * `--output DIR` - evidence directory. Default: `.pixir/smoke/websocket/<run_id>`.
    * `--probe-cache-routing` - add two cache-eligible long-prefix requests with a
      stable `prompt_cache_key`.
    * `--cache-key KEY` - cache key used by `--probe-cache-routing`.
    * `--dry-run` - validate and print planned checks without auth, network, or writes.
    * `--json` - print machine-readable evidence or errors.
    * `--help` - print this help and exit.
  """

  use Mix.Task

  import Bitwise, only: [|||: 2]

  alias Pixir.{Auth, Provider, Tool}
  alias Pixir.Provider.Cache

  @command "mix pixir.smoke.websocket"
  @schema_version 1
  @default_model "gpt-5.5"
  @default_reasoning_effort "low"
  @default_timeout_ms 30_000
  @max_response_text_chars 1_000
  @response_text_truncated_marker "\n[truncated]"
  @prompt_cache_min_input_tokens 1_024
  @codex_endpoint "wss://chatgpt.com/backend-api/codex/responses"
  @api_endpoint "wss://api.openai.com/v1/responses"
  @switches [
    model: :string,
    reasoning_effort: :string,
    endpoint: :string,
    timeout_ms: :integer,
    output: :string,
    probe_cache_routing: :boolean,
    cache_key: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]
  @aliases [h: :help, o: :output]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
      :ok
    else
      run_with_options(opts, invalid, json?)
    end
  end

  defp run_with_options(opts, invalid, json?) do
    if invalid != [] do
      fail!(
        :invalid_options,
        "Unsupported command-line option(s).",
        %{invalid: invalid},
        ["Run `#{@command} --help` to see supported options."],
        json?
      )
    end

    config = parse_config!(opts, json?)

    if config.dry_run? do
      print_dry_run(config, json?)
      :ok
    else
      Mix.Task.run("app.start")

      with {:ok, headers} <- Auth.request_headers(),
           {:ok, endpoint} <- resolve_endpoint(config.endpoint, headers),
           {:ok, evidence} <- run_smoke(%{config | endpoint: endpoint}, headers) do
        write_evidence!(config.output_dir, evidence)
        print_payload(evidence, json?)
      else
        {:error, %{error: %{kind: kind, message: message, details: details}}} ->
          fail!(kind, message, details, recovery_steps(kind), json?)

        {:error, reason} ->
          fail!(
            :websocket_smoke_failed,
            "WebSocket smoke failed.",
            %{reason: inspect(reason)},
            recovery_steps(:websocket_smoke_failed),
            json?
          )
      end
    end
  end

  defp parse_config!(opts, json?) do
    timeout_ms = positive_int!(opts, :timeout_ms, @default_timeout_ms, json?)
    run_id = timestamp()
    model = Keyword.get(opts, :model, @default_model)

    reasoning_effort =
      opts
      |> Keyword.get(:reasoning_effort, @default_reasoning_effort)
      |> normalize_reasoning_effort!(json?)

    cache_key =
      Keyword.get(opts, :cache_key) || default_cache_key!(model, reasoning_effort, json?)

    %{
      run_id: run_id,
      model: model,
      reasoning_effort: reasoning_effort,
      endpoint: Keyword.get(opts, :endpoint, "auto"),
      timeout_ms: timeout_ms,
      output_dir: Keyword.get(opts, :output, Path.join([".pixir", "smoke", "websocket", run_id])),
      probe_cache_routing?: Keyword.get(opts, :probe_cache_routing, false),
      cache_key: cache_key,
      dry_run?: Keyword.get(opts, :dry_run, false)
    }
  end

  defp positive_int!(opts, key, default, json?) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      value
    else
      option = key |> Atom.to_string() |> String.replace("_", "-")

      fail!(
        :invalid_positive_integer,
        "--#{option} must be a positive integer.",
        %{option: key, value: value},
        ["Pass a value such as `--#{option} #{default}`."],
        json?
      )
    end
  end

  defp normalize_reasoning_effort!(effort, _json?) when effort in ~w(low medium high xhigh),
    do: effort

  defp normalize_reasoning_effort!(effort, json?) do
    fail!(
      :invalid_reasoning_effort,
      "--reasoning-effort must be one of low, medium, high, xhigh.",
      %{value: effort},
      ["Pass `--reasoning-effort low` for the representative low-cost smoke."],
      json?
    )
  end

  defp default_cache_key!(model, reasoning_effort, json?) do
    case Cache.stable_hash(["websocket-cache-routing-smoke-v1", model, reasoning_effort]) do
      {:ok, hash} ->
        "px-ws-smoke:" <> hash

      {:error, reason} ->
        fail!(
          :cache_key_hash_failed,
          "Could not build the default WebSocket prompt-cache key.",
          %{reason: Exception.message(reason)},
          ["Pass an explicit stable key with `--cache-key`."],
          json?
        )
    end
  end

  defp print_help(true) do
    print_payload(
      %{
        "ok" => true,
        "schema_version" => @schema_version,
        "command" => @command,
        "network" => true,
        "default_model" => @default_model,
        "default_reasoning_effort" => @default_reasoning_effort,
        "options" => [
          "--model MODEL",
          "--reasoning-effort EFFORT",
          "--endpoint URL",
          "--timeout-ms N",
          "--output DIR",
          "--probe-cache-routing",
          "--cache-key KEY",
          "--dry-run",
          "--json",
          "--help"
        ],
        "checks" => check_names(%{probe_cache_routing?: true}),
        "dry_run_guarantees" => [
          "does_not_require_auth",
          "does_not_open_websocket",
          "does_not_call_provider",
          "does_not_create_output_dir"
        ],
        "next_steps" => [
          "Start with `#{@command} --dry-run --json`.",
          "Then run `#{@command} --json` with a valid Pixir subscription login.",
          "Use `--reasoning-effort low` for the representative low-cost default probe."
        ]
      },
      true
    )
  end

  defp print_help(_json?) do
    Mix.shell().info(@moduledoc)
  end

  defp print_dry_run(config, json?) do
    print_payload(
      %{
        "ok" => true,
        "schema_version" => @schema_version,
        "mode" => "dry_run",
        "command" => @command,
        "network" => false,
        "model" => config.model,
        "reasoning_effort" => config.reasoning_effort,
        "endpoint" => config.endpoint,
        "checks" => check_names(config),
        "estimated_response_create_calls" => estimated_response_create_calls(config),
        "probe_cache_routing" => config.probe_cache_routing?,
        "cache_key" => if(config.probe_cache_routing?, do: config.cache_key, else: nil),
        "prompt_cache_min_input_tokens" => @prompt_cache_min_input_tokens,
        "would_write" => [Path.join(config.output_dir, "evidence.json")],
        "next_steps" => [
          "Run `#{@command} --json` to execute the real WebSocket smoke.",
          "If the handshake fails, run `./pixir doctor --json` and confirm Pixir auth is ready.",
          "If same-socket continuation fails, use HTTP/SSE fallback and report the WebSocket failure reason."
        ]
      },
      json?
    )
  end

  defp run_smoke(config, headers) do
    started_at = DateTime.utc_now()

    case connect(config.endpoint, headers, config.timeout_ms) do
      {:ok, socket, initial_buffer, handshake} ->
        try do
          with {:ok, first} <-
                 request_response(socket, initial_buffer, config, "Reply exactly: ok", nil),
               {:ok, second} <-
                 request_response(socket, "", config, "Reply exactly: ok2", first.response_id),
               {:ok, tool_request} <- request_tool_call(socket, config, second.response_id),
               {:ok, tool_final} <-
                 send_tool_output(
                   socket,
                   config,
                   tool_request.response_id,
                   hd(tool_request.function_calls)
                 ),
               {:ok, cache_probe} <- maybe_probe_cache_routing(socket, config),
               :ok <- close(socket),
               {:ok, reconnect} <-
                 reconnect_miss(config.endpoint, headers, config, first.response_id) do
            completed_at = DateTime.utc_now()

            checks =
              [
                handshake_check(handshake),
                response_check("minimal_response", first, "ok"),
                response_check("same_socket_continuation", second, "ok2"),
                tool_call_check(tool_request),
                response_check("tool_output_continuation", tool_final, "ws_tool_ok"),
                reconnect_check(reconnect)
              ] ++ cache_probe_checks(cache_probe)

            ok? = Enum.all?(checks, &(&1["status"] == "passed"))

            usage =
              %{
                "minimal_response" => first.usage_summary,
                "same_socket_continuation" => second.usage_summary,
                "tool_request" => tool_request.usage_summary,
                "tool_output_continuation" => tool_final.usage_summary
              }
              |> Map.merge(cache_probe_usage(cache_probe))
              |> Map.new(fn {name, summary} ->
                {name, usage_with_cache_eligibility(summary)}
              end)

            evidence =
              %{
                "ok" => true,
                "schema_version" => @schema_version,
                "mode" => "real_network",
                "command" => @command,
                "network" => true,
                "started_at" => DateTime.to_iso8601(started_at),
                "completed_at" => DateTime.to_iso8601(completed_at),
                "model" => config.model,
                "reasoning_effort" => config.reasoning_effort,
                "endpoint" => safe_endpoint(config.endpoint),
                "output_dir" => config.output_dir,
                "probe_cache_routing" => config.probe_cache_routing?,
                "cache_key" => if(config.probe_cache_routing?, do: config.cache_key, else: nil),
                "checks" => checks,
                "usage" => usage,
                "prompt_cache_observation" => prompt_cache_observation(usage),
                "next_steps" => [
                  "Implement Provider transport policy `auto`: WebSocket first, HTTP/SSE fallback.",
                  "Capture response_id in Provider results before building continuation planning.",
                  "Measure bytes sent and latency before claiming WebSocket performance wins."
                ]
              }
              |> Map.put("ok", ok?)

            if ok? do
              {:ok, evidence}
            else
              {:error,
               Tool.error(
                 :websocket_smoke_checks_failed,
                 "One or more WebSocket smoke checks failed.",
                 %{
                   evidence: evidence
                 }
               )}
            end
          else
            {:error, reason} -> {:error, normalize_error(reason)}
          end
        after
          close(socket)
        end

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  defp connect(endpoint, headers, timeout_ms) do
    with {:ok, uri} <- parse_endpoint(endpoint),
         :ok <- Application.ensure_all_started(:ssl) |> normalize_started(),
         {:ok, socket} <- ssl_connect(uri, timeout_ms) do
      case websocket_handshake(socket, uri, headers, timeout_ms) do
        {:ok, handshake, rest} ->
          if handshake.status == 101 do
            {:ok, socket, rest, handshake}
          else
            close(socket)

            {:error,
             Tool.error(:websocket_handshake_failed, "WebSocket handshake did not upgrade.", %{
               status: handshake.status,
               status_line: handshake.status_line,
               endpoint: safe_endpoint(endpoint)
             })}
          end

        {:error, _} = error ->
          close(socket)
          error
      end
    end
  end

  defp websocket_handshake(socket, uri, headers, timeout_ms) do
    with {:ok, request_headers} <- handshake_headers(uri, headers),
         :ok <- :ssl.send(socket, request_headers),
         {:ok, handshake, rest} <- read_handshake(socket, timeout_ms) do
      {:ok, handshake, rest}
    else
      {:error, reason} ->
        {:error,
         Tool.error(:websocket_handshake_failed, "WebSocket handshake failed.", %{
           reason: inspect(reason),
           endpoint: safe_endpoint(URI.to_string(uri))
         })}
    end
  end

  defp normalize_started({:ok, _apps}), do: :ok
  defp normalize_started({:error, _} = error), do: error

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    cond do
      uri.scheme != "wss" ->
        {:error,
         Tool.error(:invalid_endpoint, "WebSocket endpoint must use wss://.", %{
           endpoint: safe_endpoint(endpoint)
         })}

      not is_binary(uri.host) ->
        {:error,
         Tool.error(:invalid_endpoint, "WebSocket endpoint must include a host.", %{
           endpoint: safe_endpoint(endpoint)
         })}

      true ->
        {:ok, %{uri | port: uri.port || 443, path: uri.path || "/"}}
    end
  end

  defp ssl_connect(uri, timeout_ms) do
    host = String.to_charlist(uri.host)

    :ssl.connect(
      host,
      uri.port,
      [
        :binary,
        active: false,
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: host,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      timeout_ms
    )
    |> case do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        {:error,
         Tool.error(:websocket_connect_failed, "Could not open TLS connection.", %{
           reason: inspect(reason),
           endpoint: safe_endpoint(URI.to_string(uri))
         })}
    end
  end

  defp handshake_headers(uri, auth_headers) do
    key = :crypto.strong_rand_bytes(16) |> Base.encode64()
    path = endpoint_path(uri)

    headers =
      [
        {"Host", host_header(uri)},
        {"Connection", "Upgrade"},
        {"Upgrade", "websocket"},
        {"Sec-WebSocket-Key", key},
        {"Sec-WebSocket-Version", "13"},
        {"openai-beta", "responses=experimental"},
        {"originator", "pixir"},
        {"User-Agent", "pixir-websocket-smoke/0.1"}
      ] ++ normalize_auth_headers(auth_headers)

    request =
      [
        "GET #{path} HTTP/1.1"
        | Enum.map(headers, fn {name, value} -> "#{name}: #{value}" end)
      ]
      |> Enum.join("\r\n")

    {:ok, request <> "\r\n\r\n"}
  end

  defp normalize_auth_headers(headers) do
    Enum.map(headers, fn
      {"authorization", value} -> {"Authorization", value}
      {"chatgpt-account-id", value} -> {"chatgpt-account-id", value}
      {name, value} -> {name, value}
    end)
  end

  defp endpoint_path(%URI{path: path, query: nil}), do: path || "/"
  defp endpoint_path(%URI{path: path, query: query}), do: (path || "/") <> "?" <> query

  defp host_header(%URI{host: host, port: 443}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  defp read_handshake(socket, timeout_ms), do: read_handshake(socket, "", timeout_ms)

  defp read_handshake(socket, buffer, timeout_ms) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, rest] when headers != buffer ->
        {:ok, parse_handshake(headers), rest}

      _ ->
        case :ssl.recv(socket, 0, timeout_ms) do
          {:ok, data} -> read_handshake(socket, buffer <> data, timeout_ms)
          {:error, reason} -> {:error, {:handshake_read_failed, reason}}
        end
    end
  end

  defp parse_handshake(headers) do
    [status_line | _] = String.split(headers, "\r\n")

    status =
      case Regex.run(~r/^HTTP\/\S+\s+(\d+)/, status_line) do
        [_, code] -> String.to_integer(code)
        _ -> nil
      end

    %{status: status, status_line: status_line}
  end

  defp request_response(socket, initial_buffer, config, text, previous_response_id) do
    payload = base_payload(config, text, previous_response_id)

    with :ok <- send_json(socket, payload),
         {:ok, response} <- read_response(socket, initial_buffer, config.timeout_ms) do
      {:ok, response}
    end
  end

  defp request_tool_call(socket, config, previous_response_id) do
    payload =
      config
      |> base_payload(
        "Call the probe_echo tool with text ws_tool_ok. After receiving the tool result, reply exactly: ws_tool_ok",
        previous_response_id
      )
      |> Map.put("tools", [probe_echo_tool()])

    with :ok <- send_json(socket, payload),
         {:ok, %{function_calls: [_ | _]} = response} <-
           read_response(socket, "", config.timeout_ms) do
      {:ok, response}
    else
      {:ok, response} ->
        {:error,
         Tool.error(:websocket_tool_call_missing, "Model did not request the probe tool.", %{
           response_text: response.text,
           event_types: response.event_types
         })}

      {:error, _} = error ->
        error
    end
  end

  defp send_tool_output(socket, config, previous_response_id, call) do
    payload =
      config
      |> base_payload(nil, previous_response_id)
      |> Map.put("input", [
        %{"type" => "function_call_output", "call_id" => call.call_id, "output" => "ws_tool_ok"}
      ])

    with :ok <- send_json(socket, payload),
         {:ok, response} <- read_response(socket, "", config.timeout_ms) do
      {:ok, response}
    end
  end

  defp maybe_probe_cache_routing(_socket, %{probe_cache_routing?: false}), do: {:ok, nil}

  defp maybe_probe_cache_routing(socket, config) do
    with {:ok, warmup} <-
           request_cache_probe(
             socket,
             config,
             "cache_routing_warmup",
             cache_routing_prompt("warmup", "WS_CACHE_WARMUP"),
             "WS_CACHE_WARMUP"
           ),
         {:ok, candidate_hit} <-
           request_cache_probe(
             socket,
             config,
             "cache_routing_candidate_hit",
             cache_routing_prompt("candidate-hit", "WS_CACHE_HIT"),
             "WS_CACHE_HIT"
           ) do
      {:ok, %{warmup: warmup, candidate_hit: candidate_hit}}
    end
  end

  defp request_cache_probe(socket, config, label, prompt, expected_text) do
    payload =
      config
      |> base_payload(prompt, nil)
      |> Map.put("prompt_cache_key", config.cache_key)

    with :ok <- send_json(socket, payload),
         {:ok, response} <- read_response(socket, "", config.timeout_ms) do
      {:ok,
       response
       |> Map.put(:label, label)
       |> Map.put(:expected_text, expected_text)}
    end
  end

  defp reconnect_miss(endpoint, headers, config, previous_response_id) do
    case connect(endpoint, headers, config.timeout_ms) do
      {:ok, socket, initial_buffer, _handshake} ->
        try do
          with :ok <-
                 send_json(
                   socket,
                   base_payload(config, "Reply exactly: should_not_work", previous_response_id)
                 ),
               {:error, error} <- read_response(socket, initial_buffer, config.timeout_ms) do
            {:ok, error}
          else
            {:ok, response} ->
              {:error,
               Tool.error(
                 :websocket_reconnect_unexpected_success,
                 "Cross-socket continuation unexpectedly succeeded.",
                 %{
                   text: response.text,
                   has_response_id: present?(response.response_id)
                 }
               )}

            {:error, _} = error ->
              error
          end
        after
          close(socket)
        end

      {:error, _} = error ->
        error
    end
  end

  defp base_payload(config, text, previous_response_id) do
    input =
      if is_binary(text) do
        [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => text}]
          }
        ]
      else
        []
      end

    %{
      "type" => "response.create",
      "model" => config.model,
      "store" => false,
      "instructions" =>
        "You are a concise WebSocket connectivity probe. Reply exactly as requested.",
      "input" => input,
      "tools" => []
    }
    |> maybe_put_reasoning(config.reasoning_effort)
    |> maybe_put_previous_response_id(previous_response_id)
  end

  defp maybe_put_reasoning(payload, effort) when effort in ~w(low medium high xhigh),
    do: Map.put(payload, "reasoning", %{"effort" => effort})

  defp maybe_put_reasoning(payload, _effort), do: payload

  defp maybe_put_previous_response_id(payload, id) when is_binary(id),
    do: Map.put(payload, "previous_response_id", id)

  defp maybe_put_previous_response_id(payload, _id), do: payload

  defp cache_routing_prompt(variant, expected_text) do
    cache_routing_prefix() <>
      "\n\nVariant: #{variant}. Reply exactly: #{expected_text}"
  end

  defp cache_routing_prefix do
    paragraph = """
    Pixir WebSocket prompt-cache routing smoke stable prefix. This text is
    intentionally synthetic, non-secret, and repeated so the Provider sees a long
    shared prefix before the final variant instruction. It describes no local files,
    no people, no paths, and no credentials. The only useful measurement is returned
    Provider usage, especially cached_tokens inside input token details.
    """

    1..34
    |> Enum.map(fn i -> "Block #{String.pad_leading(to_string(i), 2, "0")}. #{paragraph}" end)
    |> Enum.join("\n")
  end

  defp probe_echo_tool do
    %{
      "type" => "function",
      "name" => "probe_echo",
      "description" => "Echo the provided text.",
      "parameters" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["text"],
        "properties" => %{
          "text" => %{"type" => "string", "description" => "Text to echo."}
        }
      }
    }
  end

  defp send_json(socket, payload) do
    payload
    |> Jason.encode!()
    |> text_frame()
    |> then(&:ssl.send(socket, &1))
  end

  defp text_frame(text) when is_binary(text) do
    payload = IO.iodata_to_binary(text)
    mask = :crypto.strong_rand_bytes(4)
    header = frame_header(0x81, byte_size(payload), true)
    [header, mask, mask_payload(payload, mask)]
  end

  defp frame_header(opcode, length, masked?) do
    mask_bit = if masked?, do: 0x80, else: 0

    cond do
      length < 126 ->
        <<opcode, mask_bit ||| length>>

      length < 65_536 ->
        <<opcode, mask_bit ||| 126, length::16>>

      true ->
        <<opcode, mask_bit ||| 127, length::64>>
    end
  end

  defp mask_payload(payload, <<a, b, c, d>>) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      Bitwise.bxor(byte, elem({a, b, c, d}, rem(index, 4)))
    end)
    |> IO.iodata_to_binary()
  end

  defp read_response(socket, initial_buffer, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    read_response_loop(socket, initial_buffer, deadline, %{
      text: "",
      event_types: [],
      function_calls: [],
      response_id: nil,
      usage: nil
    })
  end

  defp read_response_loop(socket, buffer, deadline, acc) do
    case next_frame(buffer) do
      {:ok, frame, rest} ->
        case handle_frame(socket, frame, acc) do
          {:continue, acc} ->
            read_response_loop(socket, rest, deadline, acc)

          {:done, acc} ->
            {:ok, finalize_response(acc)}

          {:error, error} ->
            {:error, error}
        end

      {:error, error} ->
        {:error, error}

      :more ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)

        if timeout == 0 do
          {:error,
           Tool.error(:websocket_timeout, "Timed out waiting for a WebSocket response.", %{})}
        else
          case :ssl.recv(socket, 0, timeout) do
            {:ok, data} ->
              read_response_loop(socket, buffer <> data, deadline, acc)

            {:error, reason} ->
              {:error,
               Tool.error(:websocket_read_failed, "Could not read WebSocket frame.", %{
                 reason: inspect(reason)
               })}
          end
        end
    end
  end

  defp next_frame(buffer) when byte_size(buffer) < 2, do: :more

  defp next_frame(<<first, second, rest::binary>> = buffer) do
    opcode = Bitwise.band(first, 0x0F)
    masked? = Bitwise.band(second, 0x80) != 0
    base_len = Bitwise.band(second, 0x7F)

    with {:ok, len, rest} <- frame_length(base_len, rest),
         {:ok, mask, payload_and_rest} <- frame_mask(masked?, rest),
         true <- byte_size(payload_and_rest) >= len do
      <<payload::binary-size(^len), remaining::binary>> = payload_and_rest
      payload = if masked?, do: mask_payload(payload, mask), else: payload
      {:ok, %{opcode: opcode, payload: payload}, remaining}
    else
      false -> :more
      :more -> :more
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error in [ArgumentError, MatchError, FunctionClauseError] ->
      {:ok, %{opcode: 0x8, payload: buffer}, ""}
  end

  defp frame_length(len, rest) when len < 126, do: {:ok, len, rest}

  defp frame_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp frame_length(126, _rest), do: :more

  defp frame_length(127, <<len::64, rest::binary>>) when len <= 16_000_000,
    do: {:ok, len, rest}

  defp frame_length(127, <<len::64, _rest::binary>>),
    do:
      {:error,
       Tool.error(:websocket_frame_too_large, "WebSocket frame is too large.", %{bytes: len})}

  defp frame_length(127, _rest), do: :more

  defp frame_mask(false, rest), do: {:ok, <<>>, rest}
  defp frame_mask(true, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp frame_mask(true, _rest), do: :more

  defp handle_frame(_socket, %{opcode: 0x1, payload: payload}, acc) do
    case Jason.decode(payload) do
      {:ok, %{"type" => "error"} = event} ->
        error = error_payload(event)

        {:error,
         Tool.error(
           :websocket_provider_error,
           provider_error_message(error),
           sanitize_error(error)
         )}

      {:ok, %{"type" => type} = event} ->
        handle_event(type, event, acc)

      _ ->
        {:continue, acc}
    end
  end

  defp handle_frame(socket, %{opcode: 0x9, payload: payload}, acc) do
    :ok = :ssl.send(socket, pong_frame(payload))
    {:continue, acc}
  end

  defp handle_frame(_socket, %{opcode: 0x8}, _acc) do
    {:error, Tool.error(:websocket_closed, "WebSocket closed before response.completed.", %{})}
  end

  defp handle_frame(_socket, _frame, acc), do: {:continue, acc}

  defp pong_frame(payload) do
    mask = :crypto.strong_rand_bytes(4)
    [frame_header(0x8A, byte_size(payload), true), mask, mask_payload(payload, mask)]
  end

  defp handle_event("response.output_text.delta", %{"delta" => delta} = event, acc)
       when is_binary(delta) do
    {:continue, event_seen(%{acc | text: append_response_text(acc.text, delta)}, event)}
  end

  defp handle_event("response.output_text.done", %{"text" => text} = event, acc)
       when is_binary(text) do
    text = if acc.text == "", do: safe_response_text(text), else: acc.text
    {:continue, event_seen(%{acc | text: text}, event)}
  end

  defp handle_event(
         "response.content_part.done",
         %{"part" => %{"type" => "output_text", "text" => text}} = event,
         acc
       )
       when is_binary(text) do
    text = if acc.text == "", do: safe_response_text(text), else: acc.text
    {:continue, event_seen(%{acc | text: text}, event)}
  end

  defp handle_event(
         "response.output_item.done",
         %{"item" => %{"type" => "message", "content" => content}} = event,
         acc
       )
       when is_list(content) do
    text =
      content
      |> Enum.find_value(fn
        %{"type" => "output_text", "text" => text} when is_binary(text) -> text
        _ -> nil
      end)

    text = if acc.text == "" and is_binary(text), do: safe_response_text(text), else: acc.text
    {:continue, event_seen(%{acc | text: text}, event)}
  end

  defp handle_event(
         "response.output_item.done",
         %{"item" => %{"type" => "function_call"} = item} = event,
         acc
       ) do
    call = %{
      call_id: item["call_id"],
      name: item["name"],
      arguments: decode_arguments(item["arguments"])
    }

    {:continue, event_seen(%{acc | function_calls: [call | acc.function_calls]}, event)}
  end

  defp handle_event("response.failed", event, _acc) do
    error = response_failed_error(event)

    {:error,
     Tool.error(
       :websocket_provider_error,
       provider_error_message(error),
       sanitize_error(error)
     )}
  end

  defp handle_event("response.completed", %{"response" => response} = event, acc)
       when is_map(response) do
    acc =
      acc
      |> event_seen(event)
      |> Map.put(:response_id, response["id"])
      |> Map.put(:usage, response["usage"])

    {:done, acc}
  end

  defp handle_event(_type, event, acc), do: {:continue, event_seen(acc, event)}

  defp event_seen(acc, %{"type" => type}) when is_binary(type),
    do: %{acc | event_types: [type | acc.event_types]}

  defp event_seen(acc, _event), do: acc

  defp finalize_response(acc) do
    %{
      text: safe_response_text(acc.text),
      event_types: acc.event_types |> Enum.reverse() |> Enum.uniq(),
      function_calls: Enum.reverse(acc.function_calls),
      response_id: acc.response_id,
      usage: acc.usage,
      usage_summary: Provider.usage_summary(acc.usage)
    }
  end

  defp decode_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_arguments(_arguments), do: %{}

  defp error_payload(%{"error" => error}) when is_map(error), do: error
  defp error_payload(error), do: error

  defp response_failed_error(event) when is_map(event) do
    error =
      cond do
        is_map(event["error"]) ->
          event["error"]

        is_map(get_in(event, ["response", "error"])) ->
          get_in(event, ["response", "error"])

        true ->
          %{"message" => "Provider emitted response.failed.", "type" => "response_failed"}
      end

    Map.put_new(error, "type", "response_failed")
  end

  defp provider_error_message(%{"message" => message}) when is_binary(message), do: message
  defp provider_error_message(_error), do: "Provider returned a WebSocket error."

  defp sanitize_error(error) when is_map(error) do
    error
    |> Map.take(["type", "status", "code", "message", "param"])
    |> Map.update("message", nil, &(&1 |> redact_response_ids() |> truncate(240)))
  end

  defp truncate(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp truncate(value, _max), do: value

  defp append_response_text(current, delta) when is_binary(delta),
    do: safe_response_text(current <> delta)

  defp safe_response_text(text) when is_binary(text) do
    text
    |> sanitize_text()
    |> truncate_response_text()
  end

  defp safe_response_text(_text), do: ""

  defp sanitize_text(text) do
    if String.valid?(text) do
      String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
    else
      "[invalid utf8 response text]"
    end
  end

  defp truncate_response_text(text) do
    if String.length(text) > @max_response_text_chars do
      String.slice(text, 0, @max_response_text_chars) <> @response_text_truncated_marker
    else
      text
    end
  end

  defp redact_response_ids(value) when is_binary(value),
    do: String.replace(value, ~r/resp_[A-Za-z0-9]+/, "resp_<redacted>")

  defp redact_response_ids(value), do: value

  defp resolve_endpoint("auto", headers), do: resolve_endpoint(nil, headers)

  defp resolve_endpoint(nil, headers) do
    if Enum.any?(headers, fn {name, _} -> String.downcase(name) == "chatgpt-account-id" end) do
      {:ok, @codex_endpoint}
    else
      {:ok, @api_endpoint}
    end
  end

  defp resolve_endpoint(endpoint, _headers) when is_binary(endpoint), do: {:ok, endpoint}

  defp write_evidence!(output_dir, evidence) do
    File.mkdir_p!(output_dir)
    File.write!(Path.join(output_dir, "evidence.json"), Jason.encode!(evidence, pretty: true))
  end

  defp handshake_check(handshake) do
    %{
      "name" => "handshake",
      "status" => if(handshake.status == 101, do: "passed", else: "failed"),
      "evidence" => %{"http_status" => handshake.status}
    }
  end

  defp response_check(name, response, expected_text) do
    %{
      "name" => name,
      "status" =>
        if(response.text == expected_text and present?(response.response_id),
          do: "passed",
          else: "failed"
        ),
      "evidence" => %{
        "text" => response.text,
        "expected_text" => expected_text,
        "has_response_id" => present?(response.response_id),
        "has_usage" => is_map(response.usage),
        "event_types" => response.event_types
      }
    }
  end

  defp tool_call_check(response) do
    calls =
      Enum.map(response.function_calls, fn call ->
        %{
          "name" => call.name,
          "has_call_id" => present?(call.call_id),
          "arguments" => call.arguments
        }
      end)

    %{
      "name" => "tool_call_request",
      "status" =>
        if(calls != [] and present?(response.response_id), do: "passed", else: "failed"),
      "evidence" => %{
        "calls" => calls,
        "has_response_id" => present?(response.response_id),
        "has_usage" => is_map(response.usage),
        "event_types" => response.event_types
      }
    }
  end

  defp reconnect_check(%{error: %{details: details}} = error) do
    expected? =
      details["code"] == "previous_response_not_found" or
        details[:code] == "previous_response_not_found"

    %{
      "name" => "reconnect_store_false_cache_miss",
      "status" => if(expected?, do: "passed", else: "failed"),
      "evidence" => %{
        "expected_error_code" => "previous_response_not_found",
        "error_kind" => Atom.to_string(error.error.kind),
        "error_details" => details
      }
    }
  end

  defp cache_probe_checks(nil), do: []

  defp cache_probe_checks(%{warmup: warmup, candidate_hit: candidate_hit}) do
    [
      cache_probe_check("cache_routing_warmup", warmup),
      cache_probe_check("cache_routing_candidate_hit", candidate_hit)
    ]
  end

  defp cache_probe_check(name, response) do
    expected_text = response.expected_text
    usage = usage_with_cache_eligibility(response.usage_summary) || %{}

    %{
      "name" => name,
      "status" =>
        if(
          response.text == expected_text and present?(response.response_id) and
            is_map(response.usage),
          do: "passed",
          else: "failed"
        ),
      "evidence" => %{
        "text" => response.text,
        "expected_text" => expected_text,
        "has_response_id" => present?(response.response_id),
        "has_usage" => is_map(response.usage),
        "cache_eligible_by_input_tokens" => usage["cache_eligible_by_input_tokens"],
        "cached_tokens_observed" => usage["cached_tokens_observed"],
        "cached_tokens" => usage["cached_tokens"],
        "input_tokens" => usage["input_tokens"],
        "event_types" => response.event_types
      }
    }
  end

  defp cache_probe_usage(nil), do: %{}

  defp cache_probe_usage(%{warmup: warmup, candidate_hit: candidate_hit}) do
    %{
      "cache_routing_warmup" => warmup.usage_summary,
      "cache_routing_candidate_hit" => candidate_hit.usage_summary
    }
  end

  defp usage_with_cache_eligibility(summary) when is_map(summary) do
    summary = stringify(summary)
    input_tokens = token_count(summary["input_tokens"])
    cached_tokens = token_count(summary["cached_tokens"])

    Map.merge(summary, %{
      "cache_eligible_by_input_tokens" => input_tokens >= @prompt_cache_min_input_tokens,
      "cached_tokens_observed" => cached_tokens > 0,
      "prompt_cache_min_input_tokens" => @prompt_cache_min_input_tokens
    })
  end

  defp usage_with_cache_eligibility(_summary), do: nil

  defp prompt_cache_observation(usage) do
    entries =
      usage
      |> Map.values()
      |> Enum.filter(&is_map/1)

    eligible? = Enum.any?(entries, & &1["cache_eligible_by_input_tokens"])
    hit? = Enum.any?(entries, & &1["cached_tokens_observed"])

    %{
      "cache_hit_observed" => hit?,
      "all_requests_cache_ineligible_by_input_tokens" => entries != [] and not eligible?,
      "min_input_tokens" => @prompt_cache_min_input_tokens,
      "interpretation" =>
        "cached_tokens=0 is not evidence of a cache miss when every request is below the prompt-cache input-token threshold"
    }
  end

  defp token_count(value) when is_integer(value), do: value
  defp token_count(value) when is_float(value), do: trunc(value)
  defp token_count(_value), do: 0

  defp print_payload(payload, true), do: Mix.shell().info(Jason.encode!(payload, pretty: true))

  defp print_payload(payload, _json?) do
    Mix.shell().info("Pixir WebSocket smoke #{if payload["ok"], do: "passed", else: "failed"}")
    Mix.shell().info("Evidence: #{payload["output_dir"] || "(dry-run)"}")
  end

  defp fail!(kind, message, details, next_steps, true) do
    Mix.shell().error(
      Jason.encode!(
        %{
          "ok" => false,
          "schema_version" => @schema_version,
          "command" => @command,
          "error" => %{
            "kind" => Atom.to_string(kind),
            "message" => message,
            "details" => stringify(details)
          },
          "next_steps" => next_steps
        },
        pretty: true
      )
    )

    exit({:shutdown, 1})
  end

  defp fail!(kind, message, details, next_steps, _json?) do
    Mix.shell().error("#{kind}: #{message}")
    Mix.shell().error("Details: #{inspect(details)}")
    Enum.each(next_steps, &Mix.shell().error("Next: #{&1}"))
    exit({:shutdown, 1})
  end

  defp normalize_error(%{error: %{kind: _}} = error), do: error

  defp normalize_error({kind, reason}) when is_atom(kind),
    do: Tool.error(kind, "WebSocket smoke failed.", %{reason: inspect(reason)})

  defp normalize_error(reason),
    do: Tool.error(:websocket_smoke_failed, "WebSocket smoke failed.", %{reason: inspect(reason)})

  defp recovery_steps(:not_authenticated),
    do: [
      "Run `mix pixir.smoke.login --wait` and approve the device-code flow.",
      "Then rerun `#{@command} --json`."
    ]

  defp recovery_steps(:websocket_provider_error),
    do: [
      "Check the structured provider error details.",
      "Try `#{@command} --model gpt-5.5 --reasoning-effort low --json`.",
      "If continuation fails, use HTTP/SSE fallback and report the WebSocket failure reason."
    ]

  defp recovery_steps(:websocket_smoke_checks_failed),
    do: [
      "Inspect the `error.details.evidence.checks` payload for failed checks.",
      "Rerun `#{@command} --json` to rule out transient model/tool-call variation.",
      "Use HTTP/SSE fallback until every WebSocket smoke check passes."
    ]

  defp recovery_steps(_kind),
    do: [
      "Run `./pixir doctor --json` to verify local auth and runtime state.",
      "Run `#{@command} --dry-run --json` to confirm the planned smoke.",
      "Use HTTP/SSE fallback until this smoke passes."
    ]

  defp close(nil), do: :ok

  defp close(socket) do
    try do
      :ssl.close(socket)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp estimated_response_create_calls(%{probe_cache_routing?: true}), do: 7
  defp estimated_response_create_calls(_config), do: 5

  defp check_names(config) do
    base = [
      "handshake",
      "minimal_response",
      "same_socket_continuation",
      "tool_call_request",
      "tool_output_continuation",
      "reconnect_store_false_cache_miss"
    ]

    if config.probe_cache_routing? do
      base ++ ["cache_routing_warmup", "cache_routing_candidate_hit"]
    else
      base
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp safe_endpoint(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.replace(~r/(authorization|token|key)=([^&]+)/i, "\\1=<redacted>")
  end

  defp safe_endpoint(%URI{} = uri), do: safe_endpoint(URI.to_string(uri))

  defp stringify(value) when is_boolean(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, val} -> {to_string(key), stringify(val)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[^0-9TZ]/, "")
  end
end
