defmodule Mix.Tasks.Pixir.Smoke.OpenResponses do
  @shortdoc "Bounded two-call Open Responses interoperability smoke"

  @moduledoc """
  Runs a bounded, opt-in two-call HTTP/SSE tool-loop probe against the canonical
  configured `open_responses` profile.

  The command never accepts endpoint, header, token, bearer, auth, prompt, tool, or
  output text values. Help and dry-run do not read credentials, call Auth, use the
  network, or write files. Live mode makes at most two Provider calls with retries
  disabled and writes one redacted, user-only evidence envelope.

  Usage:

      mix pixir.smoke.open_responses --help
      mix pixir.smoke.open_responses --dry-run --json
      mix pixir.smoke.open_responses --json
      mix pixir.smoke.open_responses --model MODEL --timeout-ms 30000 --output DIR --json

  Options:

    * `--model MODEL` - model selected for the fixed probe.
    * `--timeout-ms N` - positive per-call idle timeout; default 30000.
    * `--output DIR` - live evidence directory; never echoed in output.
    * `--dry-run` - validate the profile, route, body, and planned calls without effects.
    * `--json` - write exactly one JSON object to stdout.
    * `--help` - print help without config, environment, credential, network, or writes.
  """

  use Mix.Task

  alias Pixir.{Event, Provider}

  alias Pixir.Provider.{
    OutputTruncation,
    ResponsesExtensions,
    ResponsesRouting
  }

  alias Pixir.Providers.{Registry, ResolvedProviderRequest, ResponsesBackend}

  @command "mix pixir.smoke.open_responses"
  @schema_version 1
  @probe_version 2
  @default_timeout_ms 30_000
  @max_evidence_bytes 32_768
  @evidence_basename "open-responses-evidence.json"
  @session_id "open-responses-smoke"
  @probe_name "pixir_open_responses_probe"
  @probe_argument "open-responses-v1"
  @final_sentinel "PIXIR_OPEN_RESPONSES_OK_V1"
  @system_prompt "You are the fixed Pixir Open Responses probe. First call the supplied function exactly once with the required constant. After its successful output, reply with exactly #{@final_sentinel} and make no further calls."
  @user_prompt "Run the fixed Open Responses probe now."
  @synthetic_output %{"ok" => true, "probe" => @probe_argument}
  @probe_digest_source ~s({"expected_args":{"probe":"open-responses-v1"},"final_sentinel":"PIXIR_OPEN_RESPONSES_OK_V1","probe_name":"pixir_open_responses_probe","probe_version":2,"synthetic_output":{"ok":true,"probe":"open-responses-v1"},"system_prompt":"You are the fixed Pixir Open Responses probe. First call the supplied function exactly once with the required constant. After its successful output, reply with exactly PIXIR_OPEN_RESPONSES_OK_V1 and make no further calls.","user_prompt":"Run the fixed Open Responses probe now."})

  # Compile-time proof that the byte-pinned digest source IS the live constants
  # (the #349 lesson: dual-maintained literals drift; this makes drift a compile
  # error instead of a silent conformance lie).
  @decoded_probe_source Jason.decode!(@probe_digest_source)
  true = @decoded_probe_source["system_prompt"] == @system_prompt
  true = @decoded_probe_source["user_prompt"] == @user_prompt
  true = @decoded_probe_source["final_sentinel"] == @final_sentinel
  true = @decoded_probe_source["probe_version"] == @probe_version
  true = @decoded_probe_source["probe_name"] == @probe_name
  true = @decoded_probe_source["expected_args"] == %{"probe" => @probe_argument}
  true = @decoded_probe_source["synthetic_output"] == @synthetic_output

  @doc false
  def probe_version, do: @probe_version

  @switches [
    model: :string,
    timeout_ms: :integer,
    output: :string,
    dry_run: :boolean,
    json: :boolean,
    help: :boolean
  ]
  @aliases [h: :help]
  @config_ingress_keys [:config_path, :raw_config, :request_snapshot_loader]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  def run(args, runtime_opts) when is_list(runtime_opts) do
    {opts, argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    json? = Keyword.get(opts, :json, false)

    if Keyword.get(opts, :help, false) do
      print_help(json?)
    else
      with :ok <- validate_cli(argv, invalid),
           {:ok, config} <- parse_config(opts),
           {:ok, context} <- resolve_context(config, runtime_opts),
           {:ok, body} <- preview_body(context) do
        config = Map.put(config, :model, context.model)

        if config.dry_run? do
          print_payload(dry_run_payload(config, context, body), json?)
        else
          Mix.Task.run("app.start")
          run_live(config, context, json?, stream_fun(runtime_opts))
        end
      else
        {:error, error} -> fail!(normalize_error(error, :invalid_config), 2, json?)
      end
    end
  end

  @doc false
  def probe_digest, do: sha256(@probe_digest_source)

  @doc false
  def claim_for_auth(:none),
    do: {"endpoint_compatibility_observed", false}

  def claim_for_auth({:bearer_env, _env_var}),
    do: {"interoperability_observed", true}

  @doc false
  def probe_definition do
    %{
      "type" => "function",
      "name" => @probe_name,
      "description" => "Return the fixed Pixir Open Responses probe value.",
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "probe" => %{"type" => "string", "enum" => [@probe_argument]}
        },
        "required" => ["probe"],
        "additionalProperties" => false
      }
    }
  end

  @doc false
  def execute_protocol(stream_fun, resolved, config)
      when is_function(stream_fun, 2) and is_map(config) do
    started = monotonic_ms()
    first_request = first_request(config.model)
    provider_opts = provider_opts(resolved, config.timeout_ms)

    case stream_fun.(first_request, provider_opts) do
      {:ok, first} ->
        case validate_first(first) do
          :ok ->
            second_request = second_request(config.model, hd(first.function_calls))

            with {:ok, second} <- stream_fun.(second_request, provider_opts),
                 :ok <- validate_second(second) do
              {:ok,
               protocol_evidence(first, second, %{
                 started_ms: started,
                 elapsed_ms: max(monotonic_ms() - started, 0)
               })}
            else
              {:error, %{error: _error} = envelope} -> {:error, envelope, 2}
              {:error, error} -> {:error, normalize_error(error, :provider_error), 2}
            end

          {:error, error} ->
            {:error, normalize_error(error, :conformance_not_observed), 1}
        end

      {:error, error} ->
        {:error, normalize_error(error, :provider_error), 1}

      _invalid ->
        {:error, smoke_error(:provider_error, :invalid_provider_result), 1}
    end
  end

  defp validate_cli([], []), do: :ok

  defp validate_cli(argv, _invalid) when argv != [],
    do: {:error, smoke_error(:invalid_config, :unexpected_args)}

  defp validate_cli(_argv, _invalid),
    do: {:error, smoke_error(:invalid_config, :invalid_options)}

  defp parse_config(opts) do
    model_override = Keyword.get(opts, :model)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    output = Keyword.get(opts, :output, Path.join([".pixir", "smoke", "open_responses"]))

    cond do
      not is_nil(model_override) and
          not (is_binary(model_override) and String.valid?(model_override) and
                   String.trim(model_override) != "") ->
        {:error, smoke_error(:invalid_config, :invalid_model)}

      not (is_integer(timeout_ms) and timeout_ms > 0) ->
        {:error, smoke_error(:invalid_config, :invalid_timeout)}

      not (is_binary(output) and String.valid?(output) and String.trim(output) != "") ->
        {:error, smoke_error(:invalid_config, :invalid_output)}

      true ->
        {:ok,
         %{
           model_override: model_override,
           timeout_ms: timeout_ms,
           output: output,
           dry_run?: Keyword.get(opts, :dry_run, false)
         }}
    end
  end

  defp resolve_context(config, runtime_opts) do
    request = first_request(config.model_override)
    provider_opts = maybe_model_opt(config.model_override)

    with {:ok, resolved} <-
           Registry.resolve_request(
             %{
               provider_intent: {:direct, Provider},
               request: request,
               provider_opts: provider_opts
             },
             Keyword.take(runtime_opts, @config_ingress_keys)
           ),
         backend <- ResolvedProviderRequest.responses_backend(resolved),
         true <- ResponsesBackend.mode(backend) == :open_responses,
         :ok <- ResponsesBackend.activation_status(backend),
         :ok <- ResponsesExtensions.validate_request(backend, request, nil),
         {:ok, routing} <- ResponsesRouting.resolve(backend, provider_transport: :auto) do
      model = ResolvedProviderRequest.model(resolved)

      {:ok,
       %{
         resolved: resolved,
         backend: backend,
         routing: routing,
         request: first_request(model),
         model: model
       }}
    else
      false -> {:error, smoke_error(:invalid_config, :open_responses_profile_required)}
      {:error, error} -> {:error, error}
    end
  end

  defp preview_body(context) do
    Provider.request_body_preview(context.request,
      resolved_provider_request: context.resolved,
      model: ResolvedProviderRequest.model(context.resolved),
      provider_transport: :auto
    )
  end

  defp first_request(model) do
    request = %{
      system_prompt: @system_prompt,
      history: [Event.user_message(@session_id, @user_prompt)],
      tools: [probe_definition()]
    }

    if is_nil(model), do: request, else: Map.put(request, :model, model)
  end

  defp maybe_model_opt(nil), do: []
  defp maybe_model_opt(model), do: [model: model]

  defp stream_fun(runtime_opts), do: Keyword.get(runtime_opts, :stream_fun, &Provider.stream/2)

  defp second_request(model, call) do
    history = [
      Event.user_message(@session_id, @user_prompt),
      Event.tool_call(@session_id, call.call_id, call.name, call.args),
      Event.tool_result(@session_id, call.call_id, %{
        "ok" => true,
        "output" => Jason.encode!(@synthetic_output)
      })
    ]

    %{
      model: model,
      system_prompt: @system_prompt,
      history: history,
      tools: [probe_definition()]
    }
  end

  defp provider_opts(resolved, timeout_ms) do
    [
      resolved_provider_request: resolved,
      provider_transport: :auto,
      stream_idle_timeout_ms: timeout_ms,
      max_retries: 0,
      on_delta: fn _delta -> :ok end
    ]
  end

  defp validate_first(result) do
    case validate_protocol_metadata(result) do
      :ok ->
        with true <- result.reasoning in [nil, ""],
             [] <- result.reasoning_items,
             [call] <- result.function_calls,
             true <- call.name == @probe_name,
             true <- call.args == %{"probe" => @probe_argument},
             :tool_calls <- result.finish_reason,
             :not_truncated <- OutputTruncation.status(result.output_truncation),
             "response.completed" <-
               OutputTruncation.provider_reason(result.output_truncation) do
          :ok
        else
          _ -> {:error, smoke_error(:conformance_not_observed, :first_call_mismatch)}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp validate_second(result) do
    case validate_protocol_metadata(result) do
      :ok ->
        with true <- result.reasoning in [nil, ""],
             [] <- result.reasoning_items,
             [] <- result.function_calls,
             true <- result.text == @final_sentinel,
             :stop <- result.finish_reason,
             :not_truncated <- OutputTruncation.status(result.output_truncation),
             "response.completed" <-
               OutputTruncation.provider_reason(result.output_truncation) do
          :ok
        else
          _ -> {:error, smoke_error(:conformance_not_observed, :second_call_mismatch)}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp validate_protocol_metadata(result) do
    metadata = result.provider_metadata || %{}
    open = metadata["open_responses"] || %{}
    counts = open["known_event_counts"] || %{}

    terminated? = open["done"] == true or open["termination"] == "eof_after_terminal"

    if metadata["active_transport"] == "http_sse" and terminated? and
         open["event_type_match"] == true and
         is_integer(counts["response.completed"]) and counts["response.completed"] >= 1 do
      :ok
    else
      {:error, smoke_error(:conformance_not_observed, :protocol_evidence_missing)}
    end
  end

  defp run_live(config, context, json?, stream_fun) do
    case execute_protocol(stream_fun, context.resolved, config) do
      {:ok, protocol} ->
        evidence = live_evidence(config, context, protocol)

        with {:ok, artifact} <- write_evidence(config.output, evidence) do
          print_payload(Map.put(evidence, "artifact", artifact), json?)
        else
          {:error, error} -> fail!(normalize_error(error, :provider_error), 1, json?)
        end

      {:error, error, attempted_calls} ->
        error = put_in(error, [:error, :details, :attempted_calls], attempted_calls)
        exit_code = if error.error.kind == :not_authenticated, do: 1, else: 1
        fail!(error, exit_code, json?)
    end
  end

  defp dry_run_payload(config, context, body) do
    backend_summary = ResponsesBackend.summary(context.backend)
    routing_summary = ResponsesRouting.summary(context.routing)

    %{
      "ok" => true,
      "schema_version" => @schema_version,
      "probe_version" => @probe_version,
      "probe_digest" => probe_digest(),
      "mode" => "dry_run",
      "network" => false,
      "writes" => false,
      "planned_calls" => 2,
      "timeout_ms" => config.timeout_ms,
      "profile" => backend_summary,
      "routing" => routing_summary,
      "endpoint_digest" => sha256(ResponsesRouting.http_url(context.routing)),
      "model_digest" => sha256(config.model),
      "extensions_applied" => ResponsesExtensions.applied_ids(context.backend),
      "extensions_omitted" => ResponsesExtensions.omitted_ids(context.backend),
      "safe_header_names" => planned_header_names(context.backend),
      "request_shape" => request_shape(body),
      "next_actions" => ["run_live_probe_when_network_spend_is_authorized"]
    }
  end

  defp live_evidence(config, context, protocol) do
    auth_policy = ResponsesBackend.auth_policy(context.backend)

    {claim, authorization_exercised?} = claim_for_auth(auth_policy)

    %{
      "ok" => true,
      "schema_version" => @schema_version,
      "probe_version" => @probe_version,
      "probe_digest" => probe_digest(),
      "mode" => "live",
      "status" => claim,
      "authorization_requirement_exercised" => authorization_exercised?,
      "attempted_calls" => 2,
      "completed_calls" => 2,
      "elapsed_ms" => protocol.elapsed_ms,
      "profile" => ResponsesBackend.summary(context.backend),
      "routing" => ResponsesRouting.summary(context.routing),
      "auth" => auth_policy_summary(auth_policy),
      "endpoint_digest" => sha256(ResponsesRouting.http_url(context.routing)),
      "model_digest" => sha256(config.model),
      "scheme" => route_scheme(context.routing),
      "host_class" => route_host_class(context.routing),
      "safe_header_names" => planned_header_names(context.backend),
      "extensions_applied" => ResponsesExtensions.applied_ids(context.backend),
      "extensions_omitted" => ResponsesExtensions.omitted_ids(context.backend),
      "calls" => protocol.calls,
      "next_actions" => ["retain_as_bounded_endpoint_observation"]
    }
  end

  defp protocol_evidence(first, second, timing) do
    %{
      elapsed_ms: timing.elapsed_ms,
      calls: [safe_call_evidence(first, 1), safe_call_evidence(second, 2)]
    }
  end

  defp safe_call_evidence(result, ordinal) do
    open = result.provider_metadata["open_responses"] || %{}

    %{
      "ordinal" => ordinal,
      "effective_transport" => result.provider_metadata["active_transport"] || "http_sse",
      "known_event_counts" => open["known_event_counts"] || %{},
      "other_event_count" => get_in(open, ["known_event_counts", "other"]) || 0,
      "event_type_match" => open["event_type_match"] == true,
      "termination" => open["termination"],
      "deviations" => if(open["done"] == true, do: [], else: ["missing_done_sentinel"]),
      "done" => open["done"] == true,
      "terminal" => OutputTruncation.to_result_map(result.output_truncation),
      "usage" => safe_usage(result.usage_summary),
      "text_bytes" => byte_size(result.text || ""),
      "reasoning_absent" => result.reasoning in [nil, ""] and result.reasoning_items == [],
      "call_count" => length(result.function_calls),
      "exact_match" => if(ordinal == 1, do: first_exact?(result), else: second_exact?(result)),
      "warning_count" => 0
    }
  end

  defp first_exact?(result) do
    match?([%{name: @probe_name, args: %{"probe" => @probe_argument}}], result.function_calls)
  end

  defp second_exact?(result), do: result.text == @final_sentinel and result.function_calls == []

  defp safe_usage(usage) do
    Map.take(usage || %{}, [
      :input_tokens,
      :cached_tokens,
      :output_tokens,
      :reasoning_tokens,
      :total_tokens
    ])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp request_shape(body) do
    %{
      "store" => body["store"],
      "stream" => body["stream"],
      "message_discriminators" =>
        Enum.all?(body["input"] || [], fn
          %{"role" => role} = item when role in ~w(user developer system assistant) ->
            item["type"] == "message"

          _other ->
            true
        end),
      "function_tool_count" => Enum.count(body["tools"] || [], &(&1["type"] == "function")),
      "include_present" => Map.has_key?(body, "include"),
      "reasoning_present" => Map.has_key?(body, "reasoning"),
      "hosted_tool_present" => Enum.any?(body["tools"] || [], &(&1["type"] != "function"))
    }
  end

  defp planned_header_names(backend) do
    auth_names =
      case ResponsesBackend.auth_policy(backend) do
        :none -> []
        {:bearer_env, _env_var} -> ["authorization"]
        :chatgpt_oauth_or_api_key -> ["authorization", "chatgpt-account-id"]
      end

    ResponsesExtensions.headers(backend)
    |> Enum.map(&elem(&1, 0))
    |> Kernel.++(auth_names)
    |> Enum.uniq()
  end

  defp auth_policy_summary(:none), do: %{"policy" => "none", "header_names" => []}

  defp auth_policy_summary({:bearer_env, env_var}),
    do: %{"policy" => "bearer_env", "env_var" => env_var, "header_names" => ["authorization"]}

  defp route_scheme(routing), do: URI.parse(ResponsesRouting.http_url(routing)).scheme

  defp route_host_class(routing) do
    host = URI.parse(ResponsesRouting.http_url(routing)).host

    cond do
      host in ["localhost", "::1"] -> "loopback"
      is_binary(host) and String.starts_with?(host, "127.") -> "loopback"
      is_binary(host) and Regex.match?(~r/^\d+(?:\.\d+){3}$/, host) -> "ip_literal"
      is_binary(host) and String.contains?(host, ":") -> "ip_literal"
      true -> "dns"
    end
  end

  defp write_evidence(output_dir, evidence) do
    encoded = Jason.encode!(evidence)

    if byte_size(encoded) > @max_evidence_bytes do
      {:error, smoke_error(:provider_error, :evidence_too_large)}
    else
      path = Path.join(output_dir, @evidence_basename)
      temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.mkdir_p(output_dir),
           :ok <- File.write(temporary, encoded, [:binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        {:ok,
         %{
           "basename" => @evidence_basename,
           "bytes" => byte_size(encoded),
           "sha256" => sha256(encoded)
         }}
      else
        _error ->
          File.rm(temporary)
          {:error, smoke_error(:provider_error, :evidence_write_failed)}
      end
    end
  rescue
    _error -> {:error, smoke_error(:provider_error, :evidence_write_failed)}
  end

  defp print_help(true) do
    print_payload(
      %{
        "ok" => true,
        "schema_version" => @schema_version,
        "command" => @command,
        "options" => [
          "--model MODEL",
          "--timeout-ms N",
          "--output DIR",
          "--dry-run",
          "--json",
          "--help"
        ],
        "planned_calls" => 2,
        "probe_version" => @probe_version,
        "probe_digest" => probe_digest(),
        "guarantees" => [
          "help_reads_no_config_or_credentials",
          "dry_run_reads_no_credentials_and_makes_no_network_calls_or_writes",
          "live_makes_at_most_two_provider_calls_with_no_tool_execution"
        ]
      },
      true
    )
  end

  defp print_help(_json?), do: Mix.shell().info(@moduledoc)

  defp print_payload(payload, true), do: Mix.shell().info(Jason.encode!(payload))

  defp print_payload(payload, _json?) do
    Mix.shell().info(
      "#{@command}: #{payload["status"] || payload["mode"] || "ready"}; calls=#{payload["completed_calls"] || payload["planned_calls"] || 0}"
    )
  end

  defp fail!(error, exit_code, true) do
    print_payload(error_payload(error), true)
    exit({:shutdown, exit_code})
  end

  defp fail!(error, exit_code, _json?) do
    Mix.shell().error("#{error.error.kind}: #{safe_error_message(error.error.kind)}")
    Mix.shell().error("next: inspect_safe_error_kind")
    exit({:shutdown, exit_code})
  end

  defp error_payload(error) do
    %{
      "ok" => false,
      "schema_version" => @schema_version,
      "probe_version" => @probe_version,
      "status" => status_for_kind(error.error.kind),
      "error" => %{
        "kind" => Atom.to_string(error.error.kind),
        "message" => safe_error_message(error.error.kind),
        "details" => safe_error_details(error.error)
      },
      "next_actions" => ["inspect_profile_and_safe_error_kind"]
    }
  end

  defp normalize_error(%{ok: false, error: %{kind: _kind} = inner}, _fallback),
    do: %{ok: false, error: inner}

  defp normalize_error(%{error: %{kind: _kind} = inner}, _fallback),
    do: %{ok: false, error: inner}

  defp normalize_error(%{kind: kind, message: message, details: details}, _fallback),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}

  defp normalize_error(_error, fallback), do: smoke_error(fallback, :bounded_failure)

  defp safe_error_message(:not_authenticated), do: "The configured credential is unavailable."

  defp safe_error_message(:invalid_config),
    do: "The Open Responses smoke configuration is invalid."

  defp safe_error_message(:conformance_not_observed),
    do: "The bounded Open Responses behavior was not observed."

  defp safe_error_message(_kind), do: "The Open Responses Provider attempt failed."

  defp safe_error_details(error) do
    details = error.details || %{}

    %{
      "reason" => safe_reason(details[:reason] || details["reason"]),
      "status" => safe_integer(details[:status] || details["status"]),
      "attempted_calls" => safe_integer(details[:attempted_calls])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason) and byte_size(reason) <= 80, do: reason
  defp safe_reason(_reason), do: nil

  defp safe_integer(value) when is_integer(value), do: value
  defp safe_integer(_value), do: nil

  defp status_for_kind(:invalid_config), do: "invalid_config"
  defp status_for_kind(:not_authenticated), do: "not_authenticated"
  defp status_for_kind(:conformance_not_observed), do: "conformance_not_observed"
  defp status_for_kind(_kind), do: "provider_error"

  defp smoke_error(kind, reason) do
    %{
      ok: false,
      error: %{
        kind: kind,
        message: "Open Responses smoke failed safely.",
        details: %{reason: reason, next_action: :inspect_profile_and_safe_error_kind}
      }
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp sha256(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
