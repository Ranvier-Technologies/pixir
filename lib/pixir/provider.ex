defmodule Pixir.Provider do
  @moduledoc """
  The Provider (ADR 0002/0003/0019): the OpenAI **Responses API** dialect, reached with
  either Credential kind. Pixir always sends `store: false`; the local Log remains the
  source of truth. The HTTP/SSE path sends folded **History** as full input. The
  WebSocket path may use connection-local `previous_response_id` and a late delta as an
  optimization, but it never replaces Log replay.

  `stream/2` performs one streamed model call:

    * ephemeral `text` / `reasoning` deltas are delivered to the `:on_delta` callback
      as `{:text_delta, chunk}` / `{:reasoning_delta, chunk}` (the Turn loop turns
      these into ephemeral Events — keeping this module free of bus/Session deps);
    * the assembled result `%{text, reasoning, function_calls, finish_reason}` is
      returned for the Turn loop to persist (the final `assistant_message`) and to
      decide whether to run tools.

  Errors are structured (ADR 0005). Tests may still inject `:transport` directly; the
  production path uses `Pixir.Provider.TransportPolicy` (`:auto | :websocket |
  :http_sse`) so WebSocket can be preferred while HTTP/SSE remains fallback. Routing is
  frozen once per stream invocation; authentication is resolved once per logical
  attempt and reused by any transport fallback inside that attempt. An explicit
  `open_responses` backend uses the portable HTTP/SSE body/header policy, strict WHATWG
  framing, generated pinned-schema validation before capability policy, and a
  conservative no-reasoning/nonportable-output boundary; the default ChatGPT/Codex
  wire and compatibility reducer remain separate.
  Known strict-open events alone reach that reducer; unknown matched event names are
  counted as bounded `other` evidence and their payloads remain opaque.
  """

  alias Pixir.{BranchSummary, Compaction, Config, Event, Skills}
  alias Pixir.Providers.{ErrBody, Registry, ResolvedProviderRequest, ResponsesBackend}

  alias Pixir.Provider.{
    FinchTransport,
    HostedTools,
    OutputTruncation,
    ResponsesAuth,
    ResponsesExtensions,
    ResponsesRouting,
    SSEDecoder,
    StreamIdle,
    ToolCall,
    TransportError,
    TransportPolicy
  }

  @default_model "gpt-5.5"
  @default_max_retries 2
  @config_ingress_keys [:config_path, :raw_config, :request_snapshot_loader]

  # The built-in model catalog (ADR 0009 / epic A.5). The same OpenAI/Codex
  # family the client may pick from; a `~/.pixir/config.json` `"models"` array
  # overrides/extends it. The default (the active `default_model/0`) is flagged
  # so the client's picker can mark it. Used to advertise the catalog over ACP
  # and to reject an unknown per-turn `_meta.model` early (`-32602`).
  @built_in_models ~w(
    gpt-5.6-sol
    gpt-5.6
    gpt-5.5
    gpt-5.4
    gpt-5.4-mini
    gpt-5.3-codex
    gpt-5.3-codex-spark
    gpt-5.2
  )

  @type request :: %{
          optional(:model) => String.t(),
          optional(:system_prompt) => String.t(),
          # px2 (ADR 0020): the late developer-context item. REQUIRED in practice
          # whenever :system_prompt is Turn.system_prompt/3 — that prompt promises a
          # developer message naming the workspace root, so omitting this sends the
          # model a false premise and no workspace at all. Build it with
          # Turn.developer_context/3.
          optional(:developer_context) => String.t(),
          optional(:workspace) => String.t(),
          optional(:history) => [map()],
          optional(:tools) => [map()],
          optional(:hosted_tools) => [map()],
          optional(:web_search) => map() | keyword() | boolean(),
          optional(:prompt_cache_key) => String.t(),
          optional(:prompt_cache_retention) => String.t(),
          optional(:output_schema) => map()
        }

  @type result :: %{
          text: String.t(),
          reasoning: String.t(),
          reasoning_items: [map()],
          function_calls: [%{call_id: String.t(), name: String.t(), args: map()}],
          output_items: [
            {:reasoning, map()} | {:function_call, map()} | {:provider_hosted_tool, map()}
          ],
          provider_hosted_tools: map(),
          web_search: map(),
          finish_reason: :stop | :tool_calls,
          usage: map() | nil,
          usage_summary: map(),
          provider_metadata: map(),
          output_truncation: OutputTruncation.t()
        }

  @doc """
  Stream one Responses call, retrying transient failures (network, `:rate_limited`,
  5xx) with capped exponential backoff. Terminal errors (`:usage_limit_reached`,
  `:model_not_supported`, auth) are not retried. See the module doc for the result
  shape. Options: `:max_retries` (default 2), `:sleep` (injectable for tests).
  """
  @spec stream(request(), keyword()) :: {:ok, result()} | {:error, map()}
  def stream(request, opts \\ [])

  def stream(request, opts) when is_map(request) and not is_struct(request) do
    with {:ok, resolved, opts} <- ensure_resolved(request, opts),
         :ok <- validate_requested_capabilities(resolved, request, opts),
         {:ok, _routing, opts} <- resolve_routing(resolved, opts) do
      max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
      sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

      request = Map.put(request, :model, ResolvedProviderRequest.model(resolved))
      attempt(request, opts, 0, max_retries, sleep)
    end
  end

  def stream(_request, _opts) do
    {:error,
     err(:invalid_args, "stream/2 requires a plain Provider request map.", %{
       expected: "plain_map"
     })}
  end

  @doc "Whether this Provider accepts an explicit Responses backend selection."
  def responses_backend_compatible?, do: true

  defp attempt(request, opts, n, max, sleep) do
    case do_stream(request, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        if n < max and retryable?(error) do
          sleep.(backoff_ms(n))
          attempt(request, opts, n + 1, max, sleep)
        else
          {:error, error}
        end
    end
  end

  defp backoff_ms(n), do: min(8_000, 500 * Integer.pow(2, n))

  defp retryable?(%{error: %{kind: kind}}) when kind in [:network, :rate_limited], do: true

  defp retryable?(%{error: %{kind: :provider_http_error, details: %{retryable: true}}}), do: true

  defp retryable?(%{error: %{kind: :provider_http_error, details: %{status: status}}})
       when status in [500, 502, 503, 504], do: true

  defp retryable?(_error), do: false

  defp do_stream(request, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    resolved = Keyword.fetch!(opts, :resolved_provider_request)
    routing = Keyword.fetch!(opts, :responses_routing)
    request_url = ResponsesRouting.http_url(routing)
    model = resolved_model!(opts)
    backend = ResolvedProviderRequest.responses_backend(resolved)
    backend_mode = ResponsesBackend.mode(backend)

    reasoning_effort =
      normalize_reasoning_effort(request[:reasoning_effort] || opts[:reasoning_effort])

    text_verbosity =
      normalize_text_verbosity(request[:text_verbosity] || opts[:text_verbosity])

    with {:ok, body} <-
           build_body(model, request, reasoning_effort, text_verbosity, backend),
         {:ok, encoded_body} <- encode_body(body),
         {:ok, request_auth} <- ResponsesAuth.resolve(resolved, routing, opts) do
      http_request = %{
        method: :post,
        url: request_url,
        headers: ResponsesExtensions.headers(backend) ++ ResponsesAuth.headers(request_auth),
        body: encoded_body
      }

      init = %{
        status: nil,
        buffer: "",
        sse_decoder: if(backend_mode == :open_responses, do: SSEDecoder.new(), else: nil),
        backend_mode: backend_mode,
        open_event_counts: %{},
        open_done: false,
        open_event_type_match: true,
        terminal_event_type: nil,
        err_body: ErrBody.new(),
        text: "",
        reasoning: "",
        stream_error: nil,
        terminal_evidence: nil,
        provider_metadata: %{},
        # `output_items` holds reasoning items and function calls in SSE arrival order
        # (ADR 0007): the Turn loop records them in that order so `seq` keeps every
        # `rs_` ahead of its paired `fc_`. Reversed once at finalize.
        output_items: [],
        provider_hosted_tools: %{
          "web_search" => %{"events" => [], "calls" => [], "annotations" => [], "sources" => []}
        },
        usage: nil,
        usage_summary: usage_summary(nil),
        on_delta: on_delta
      }

      case run(request, opts, http_request, init) do
        {:ok, acc} ->
          acc |> finish_sse() |> finalize()

        {:error, reason, acc} ->
          {:error, TransportError.project(reason, status: acc.status)}

        {:error, reason} ->
          {:error, TransportError.project(reason)}
      end
    else
      {:error, %{kind: kind, message: message, details: details}} ->
        {:error, err(kind, message, details)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Resolve the model id (open knob) through `Pixir.Config.load/1`'s effective snapshot.
  That snapshot applies this precedence:

    1. `config :pixir, :model` (programmatic override)
    2. `PIXIR_MODEL` env var
    3. `~/.pixir/config.json` → `"model"`
    4. the built-in default (`#{@default_model}`) when earlier values are absent or blank
  """
  def default_model do
    case get_in(Config.load(), ["effective", "model"]) do
      model when is_binary(model) and model != "" -> model
      _ -> @default_model
    end
  end

  @doc """
  The model catalog Pixir advertises to a client (epic A.5). A list of
  `%{"id" => slug, "name" => label, "default" => bool}` (string-keyed so it
  rides ACP `_meta` verbatim). Source: the built-in list (`#{@default_model}` &
  family), extended/overridden by a `~/.pixir/config.json` `"models"` array of
  slugs if present. The active `default_model/0` is always included and flagged
  `default: true` (so the client's picker has a default even if config narrows
  the list).
  """
  @spec models(keyword()) :: [%{required(String.t()) => String.t() | boolean()}]
  def models(opts \\ []) do
    default = default_model()

    config_models(opts)
    |> Kernel.||(@built_in_models)
    |> List.insert_at(0, default)
    |> Enum.uniq()
    |> Enum.map(fn slug -> %{"id" => slug, "name" => slug, "default" => slug == default} end)
  end

  @doc """
  Whether `model_id` is in the advertised catalog (`models/0`). Used to reject an
  unknown per-turn `_meta.model` before it reaches the backend (epic A.5,
  decision #8 — fail early with `-32602` rather than passing through to a backend
  `model_not_supported`).
  """
  @spec model_supported?(String.t()) :: boolean()
  def model_supported?(model_id) when is_binary(model_id) do
    Enum.any?(models(), &(&1["id"] == model_id))
  end

  def model_supported?(_), do: false

  @doc """
  Build a Responses request body preview without auth or network.

  This uses the same request-shaping path as `stream/2`, including Provider-hosted
  tools, prompt-cache fields, and the px2 developer-context item. Smoke tasks should
  still bound/redact the returned body before printing it.
  """
  @spec request_body_preview(request(), keyword()) :: {:ok, map()} | {:error, map()}
  def request_body_preview(request, opts \\ [])

  def request_body_preview(request, opts) when is_map(request) and not is_struct(request) do
    with {:ok, resolved, opts} <- ensure_resolved(request, opts),
         :ok <- validate_requested_capabilities(resolved, request, opts),
         {:ok, _routing, opts} <- resolve_routing(resolved, opts) do
      model = ResolvedProviderRequest.model(resolved)
      backend = ResolvedProviderRequest.responses_backend(resolved)

      reasoning_effort =
        normalize_reasoning_effort(request[:reasoning_effort] || opts[:reasoning_effort])

      text_verbosity =
        normalize_text_verbosity(request[:text_verbosity] || opts[:text_verbosity])

      build_body(
        model,
        Map.put(request, :model, model),
        reasoning_effort,
        text_verbosity,
        backend
      )
    end
  end

  def request_body_preview(_request, _opts) do
    {:error,
     %{
       kind: :invalid_args,
       message: "request_body_preview/2 requires a plain Provider request map.",
       details: %{"expected" => "plain_map"}
     }}
  end

  # A `"models"` array of slug strings from `~/.pixir/config.json`, or nil when
  # absent/malformed (falls back to the built-in list). Non-string entries are
  # dropped; an empty/invalid array yields nil so the built-in list stands.
  defp config_models(opts), do: Config.file_models(opts)

  # Raw built-in slugs, without the default-model insertion `models/1` applies.
  # The refresh diff base needs the unshaped source list.
  @doc false
  @spec built_in_models() :: [String.t()]
  def built_in_models, do: @built_in_models

  @doc """
  Cheaply validate connectivity and the model id: a minimal streamed call (tiny
  prompt, no tools). Returns `{:ok, %{model: id}}` if the backend accepts it, or the
  structured error otherwise (e.g. a `provider_http_error` for a bad model id). Useful
  before committing to a full Turn.
  """
  @spec probe(keyword()) :: {:ok, %{model: String.t()}} | {:error, map()}
  def probe(opts \\ []) do
    request = %{
      system_prompt: "You are a connectivity probe. Reply with the single word: ok.",
      history: [Event.user_message("probe", "ping")]
    }

    with {:ok, resolved, opts} <- ensure_resolved(request, opts),
         :ok <- validate_requested_capabilities(resolved, request, opts),
         {:ok, _routing, opts} <- resolve_routing(resolved, opts) do
      opts = Keyword.put(opts, :on_delta, fn _ -> :ok end)
      max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
      sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
      model = ResolvedProviderRequest.model(resolved)

      case attempt(Map.put(request, :model, model), opts, 0, max_retries, sleep) do
        {:ok, _result} -> {:ok, %{model: model}}
        {:error, _} = error -> error
      end
    end
  end

  @doc "Map a tool definition from a `__tool__/0` callback to a Responses function tool."
  @spec tool_spec(map()) :: map()
  def tool_spec(%{name: name, description: desc, parameters: params}) do
    %{"type" => "function", "name" => name, "description" => desc, "parameters" => params}
  end

  # ── request building ──────────────────────────────────────────────────────

  defp build_body(model, request, reasoning_effort, text_verbosity, backend) do
    with {:ok, history} <- request_history(request),
         {:ok, inputs} <- request_body_inputs(request),
         {:ok, hosted_tools} <- HostedTools.from_request(request),
         {:ok, hosted_include} <- HostedTools.include_fields(request, hosted_tools) do
      tools = inputs.tools ++ hosted_tools

      include =
        []
        |> maybe_add_extension_value(
          ResponsesExtensions.allowed?(backend, :reasoning_encrypted_content),
          "reasoning.encrypted_content"
        )
        |> maybe_add_extension_values(
          ResponsesExtensions.allowed?(backend, :hosted_tool_includes),
          hosted_include
        )
        |> Enum.uniq()

      folded_input =
        developer_context_items(inputs.developer_context) ++
          fold_input(history, model, workspace: inputs.workspace)

      body = %{
        "model" => model,
        "store" => false,
        "stream" => true,
        "instructions" => inputs.system_prompt,
        "input" =>
          folded_input
          |> openai_input_items()
          |> then(&ResponsesExtensions.project_input(backend, &1)),
        "tool_choice" => "auto",
        "parallel_tool_calls" => true
      }

      {:ok,
       body
       |> maybe_put_include(include)
       |> maybe_put_reasoning(reasoning_effort)
       |> maybe_put_text(inputs.output_schema, text_verbosity)
       |> maybe_put_tools(tools)
       |> maybe_put_prompt_cache_key(
         inputs.prompt_cache_key,
         backend
       )
       |> maybe_put_prompt_cache_retention(
         inputs.prompt_cache_retention,
         backend
       )}
    end
  end

  defp request_history(request) do
    case fetch_request_value(request, :history) do
      {:ok, history} -> validate_history(history)
      :absent -> {:ok, []}
      {:error, reason} -> invalid_history(reason)
    end
  end

  defp request_body_inputs(request) do
    with {:ok, system_prompt} <-
           request_text_field(request, :system_prompt, "You are a helpful coding assistant."),
         {:ok, developer_context} <- request_text_field(request, :developer_context, nil),
         {:ok, workspace} <- request_workspace(request),
         {:ok, tools} <- request_tools(request),
         {:ok, output_schema} <- request_output_schema(request),
         {:ok, prompt_cache_key} <- request_text_field(request, :prompt_cache_key, nil),
         {:ok, prompt_cache_retention} <-
           request_text_field(request, :prompt_cache_retention, nil) do
      {:ok,
       %{
         system_prompt: system_prompt,
         developer_context: developer_context,
         workspace: workspace,
         tools: tools,
         output_schema: output_schema,
         prompt_cache_key: prompt_cache_key,
         prompt_cache_retention: prompt_cache_retention
       }}
    end
  end

  defp request_text_field(request, field, default) do
    case fetch_request_value(request, field) do
      :absent ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        if String.valid?(value),
          do: {:ok, value},
          else: invalid_request_field(field, "invalid_utf8")

      {:ok, _value} ->
        invalid_request_field(field, "invalid_type")

      {:error, reason} ->
        invalid_request_field(field, reason)
    end
  end

  defp request_workspace(request) do
    case fetch_request_value(request, :workspace) do
      :absent -> default_workspace()
      {:ok, nil} -> default_workspace()
      {:ok, value} when is_binary(value) -> request_text_field(request, :workspace, nil)
      {:ok, _value} -> invalid_request_field(:workspace, "invalid_type")
      {:error, reason} -> invalid_request_field(:workspace, reason)
    end
  end

  defp default_workspace do
    case File.cwd() do
      {:ok, workspace} -> {:ok, workspace}
      {:error, _reason} -> invalid_request_field(:workspace, "cwd_unavailable")
    end
  end

  defp request_tools(request) do
    case fetch_request_value(request, :tools) do
      :absent ->
        {:ok, []}

      {:ok, nil} ->
        {:ok, []}

      {:ok, tools} when is_list(tools) ->
        if proper_list?(tools) and
             Enum.all?(tools, fn tool ->
               is_map(tool) and not is_struct(tool) and json_safe_request_term?(tool)
             end) do
          {:ok, tools}
        else
          invalid_request_field(:tools, "invalid_tool_list")
        end

      {:ok, _tools} ->
        invalid_request_field(:tools, "invalid_tool_list")

      {:error, reason} ->
        invalid_request_field(:tools, reason)
    end
  end

  defp request_output_schema(request) do
    case fetch_request_value(request, :output_schema) do
      :absent ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, schema} when is_map(schema) and not is_struct(schema) ->
        if json_safe_request_term?(schema),
          do: {:ok, schema},
          else: invalid_request_field(:output_schema, "invalid_json_schema")

      {:ok, _schema} ->
        invalid_request_field(:output_schema, "invalid_json_schema")

      {:error, reason} ->
        invalid_request_field(:output_schema, reason)
    end
  end

  defp fetch_request_value(request, field) do
    string_field = Atom.to_string(field)

    case {Map.fetch(request, field), Map.fetch(request, string_field)} do
      {{:ok, _atom_value}, {:ok, _string_value}} -> {:error, "normalized_key_collision"}
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {:error, :error} -> :absent
    end
  end

  defp validate_history(history) when is_list(history) do
    cond do
      not proper_list?(history) ->
        invalid_history("invalid_event_list")

      Enum.any?(history, &history_envelope_collision?/1) ->
        invalid_history("normalized_key_collision")

      Enum.all?(history, &valid_history_event?/1) ->
        {:ok, Enum.map(history, &normalize_history_event/1)}

      true ->
        invalid_history("invalid_event_list")
    end
  end

  defp validate_history(_history), do: invalid_history("invalid_event_list")

  defp valid_history_event?(%{type: type, data: data} = event) do
    seq = Map.get(event, :seq)
    session_id = Map.get(event, :session_id, "")
    id = Map.get(event, :id, "")
    ts = Map.get(event, :ts, "")

    not is_struct(event) and type in Event.canonical_types() and is_map(data) and
      not is_struct(data) and
      json_safe_request_term?(data) and (is_nil(seq) or (is_integer(seq) and seq >= 0)) and
      is_binary(session_id) and String.valid?(session_id) and is_binary(id) and
      String.valid?(id) and is_binary(ts) and String.valid?(ts)
  end

  defp valid_history_event?(_event), do: false

  defp history_envelope_collision?(event) when is_map(event) do
    Enum.any?([:type, :data, :seq, :session_id, :id, :ts], fn field ->
      Map.has_key?(event, field) and Map.has_key?(event, Atom.to_string(field))
    end)
  end

  defp history_envelope_collision?(_event), do: false

  defp normalize_history_event(event) do
    event
    |> Map.put_new(:seq, nil)
    |> Map.put_new(:session_id, "")
    |> Map.put_new(:id, "")
    |> Map.put_new(:ts, "")
  end

  defp json_safe_request_term?(value)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: true

  defp json_safe_request_term?(value) when is_binary(value), do: String.valid?(value)

  defp json_safe_request_term?(value) when is_list(value) do
    proper_list?(value) and Enum.all?(value, &json_safe_request_term?/1)
  end

  defp json_safe_request_term?(value) when is_struct(value), do: false

  defp json_safe_request_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} ->
      is_binary(key) and String.valid?(key) and json_safe_request_term?(nested)
    end)
  end

  defp json_safe_request_term?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp invalid_history(reason) do
    {:error,
     %{
       kind: :invalid_args,
       message: "Provider request history must be a proper list of canonical Events.",
       details: %{"field" => "history", "reason" => reason}
     }}
  end

  defp invalid_request_field(field, reason) do
    {:error,
     %{
       kind: :invalid_args,
       message: "Provider request body fields must use valid JSON-safe values.",
       details: %{"field" => Atom.to_string(field), "reason" => reason}
     }}
  end

  defp encode_body(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> invalid_request_field(:body, "not_json_encodable")
    end
  rescue
    _exception -> invalid_request_field(:body, "not_json_encodable")
  catch
    _kind, _reason -> invalid_request_field(:body, "not_json_encodable")
  end

  defp ensure_resolved(request, opts) do
    with {:ok, resolved} <- resolved_for_entry(request, opts),
         :ok <- validate_entry_resolution(resolved),
         :ok <-
           ResponsesBackend.activation_status(ResolvedProviderRequest.responses_backend(resolved)) do
      opts =
        resolved
        |> ResolvedProviderRequest.attach_to_provider_opts(
          Keyword.drop(opts, @config_ingress_keys)
        )

      {:ok, resolved, opts}
    end
  end

  defp validate_requested_capabilities(resolved, request, opts) do
    backend = ResolvedProviderRequest.responses_backend(resolved)
    ResponsesExtensions.validate_request(backend, request, requested_reasoning(request, opts))
  end

  defp requested_reasoning(request, opts) do
    case {Map.fetch(request, :reasoning_effort), Map.fetch(request, "reasoning_effort")} do
      {{:ok, atom_value}, :error} -> atom_value
      {:error, {:ok, string_value}} -> string_value
      {{:ok, _atom_value}, {:ok, _string_value}} -> :normalized_key_collision
      {:error, :error} -> Keyword.get(opts, :reasoning_effort)
    end
  end

  defp resolve_routing(%ResolvedProviderRequest{} = resolved, opts) do
    backend = ResolvedProviderRequest.responses_backend(resolved)

    with {:ok, routing} <- ResponsesRouting.resolve(backend, opts) do
      {:ok, routing, ResponsesRouting.apply_to_opts(routing, opts)}
    end
  end

  defp resolved_for_entry(request, opts) do
    case Keyword.fetch(opts, :resolved_provider_request) do
      {:ok, %ResolvedProviderRequest{} = resolved} ->
        {:ok, resolved}

      {:ok, _invalid} ->
        invalid_resolved_request()

      :error ->
        Registry.resolve_request(
          %{
            provider_intent: {:direct, __MODULE__},
            request: request,
            provider_opts: opts
          },
          Keyword.take(opts, @config_ingress_keys)
        )
    end
  end

  defp validate_entry_resolution(%ResolvedProviderRequest{} = resolved) do
    backend = ResolvedProviderRequest.responses_backend(resolved)
    model = ResolvedProviderRequest.model(resolved)
    capabilities = ResolvedProviderRequest.capabilities(resolved)

    if ResolvedProviderRequest.provider(resolved) == __MODULE__ and
         ResolvedProviderRequest.dialect(resolved) == :responses and
         is_binary(model) and String.valid?(model) and String.trim(model) != "" and
         is_map(capabilities) and
         ResponsesBackend.valid?(backend) and
         ResolvedProviderRequest.provider_defaults_valid?(resolved) and
         ResolvedProviderRequest.capabilities_valid?(resolved) and
         ResolvedProviderRequest.source_evidence_valid?(resolved) do
      :ok
    else
      invalid_resolved_request()
    end
  end

  defp invalid_resolved_request do
    {:error,
     Pixir.Tool.error(:invalid_config, "The resolved Provider request is incompatible.", %{
       field: :resolved_provider_request,
       reason: :invalid_resolved_request
     })}
  end

  defp resolved_model!(opts) do
    opts
    |> Keyword.fetch!(:resolved_provider_request)
    |> ResolvedProviderRequest.model()
  end

  # Late developer context (px2 Prompt Contract, ADR 0020): volatile session
  # facts (workspace root, mode) ride as a developer-role input item AHEAD of
  # folded History instead of inside the cacheable instructions prefix.
  # Authority comes from the developer role; cacheability comes from the
  # byte-stable instructions that precede it.
  defp developer_context_items(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        []

      trimmed ->
        [%{"role" => "developer", "content" => [%{"type" => "input_text", "text" => trimmed}]}]
    end
  end

  defp developer_context_items(_), do: []

  # Defense in depth behind the `to_input_item/3` dialect guard: the request
  # boundary stays deterministic even if a future fold path surfaces a raw
  # Anthropic thinking block through another route.
  defp openai_input_items(items) when is_list(items) do
    Enum.reject(items, fn
      %{"type" => type} when type in ["thinking", "redacted_thinking"] -> true
      _item -> false
    end)
  end

  # Set the Responses-API reasoning effort when the client picked one; otherwise
  # omit it and let the model use its own default.
  defp maybe_put_reasoning(body, nil), do: body
  defp maybe_put_reasoning(body, effort), do: Map.put(body, "reasoning", %{"effort" => effort})

  defp maybe_put_include(body, []), do: body
  defp maybe_put_include(body, include), do: Map.put(body, "include", include)

  defp maybe_add_extension_value(values, true, value), do: values ++ [value]
  defp maybe_add_extension_value(values, false, _value), do: values

  defp maybe_add_extension_values(values, true, added), do: values ++ added
  defp maybe_add_extension_values(values, false, _added), do: values

  defp maybe_put_text(body, %{"name" => name, "schema" => schema} = format, _verbosity)
       when is_binary(name) and is_map(schema) do
    Map.put(body, "text", %{"format" => json_schema_format(format)})
  end

  defp maybe_put_text(body, _output_schema, verbosity),
    do: maybe_put_text_verbosity(body, verbosity)

  defp maybe_put_text_verbosity(body, nil), do: body

  defp maybe_put_text_verbosity(body, verbosity),
    do: Map.put(body, "text", %{"verbosity" => verbosity})

  defp json_schema_format(%{"name" => name, "schema" => schema} = format)
       when is_binary(name) and is_map(schema) do
    %{
      "type" => "json_schema",
      "name" => name,
      "schema" => schema,
      "strict" => Map.get(format, "strict", true)
    }
  end

  defp maybe_put_tools(body, tools) when is_list(tools) and tools != [],
    do: Map.put(body, "tools", tools)

  defp maybe_put_tools(body, _), do: body

  # A prompt_cache_key is a bounded, non-secret routing hint (e.g.
  # "px1:m_gpt-5.5:r_build:s_abc"). Only forward keys that fit that shape so a
  # raw path, user text, or secret mistakenly threaded here never leaves as
  # cache metadata: at most 512 bytes and printable ASCII with no control
  # characters or whitespace. An out-of-shape key is dropped, not sent.
  @max_prompt_cache_key_bytes 512
  @prompt_cache_key_regex ~r/\A[\x21-\x7E]+\z/

  defp maybe_put_prompt_cache_key(body, key, backend) do
    if valid_prompt_cache_key?(key) and
         ResponsesExtensions.allowed?(backend, :prompt_cache_key),
       do: Map.put(body, "prompt_cache_key", key),
       else: body
  end

  defp valid_prompt_cache_key?(key) when is_binary(key) do
    byte_size(key) in 1..@max_prompt_cache_key_bytes and
      Regex.match?(@prompt_cache_key_regex, key)
  end

  defp valid_prompt_cache_key?(_key), do: false

  defp maybe_put_prompt_cache_retention(body, retention, backend) do
    if retention in ["24h", "in_memory"] and
         ResponsesExtensions.allowed?(backend, :prompt_cache_retention),
       do: Map.put(body, "prompt_cache_retention", retention),
       else: body
  end

  # Accept the reasoning efforts these models support; anything else (including
  # nil) falls through to the model default. Tolerates a string or atom.
  @valid_reasoning_efforts ~w(low medium high xhigh)
  defp normalize_reasoning_effort(effort) when is_atom(effort) and not is_nil(effort),
    do: normalize_reasoning_effort(Atom.to_string(effort))

  defp normalize_reasoning_effort(effort) when is_binary(effort) do
    trimmed = String.trim(effort)
    if trimmed in @valid_reasoning_efforts, do: trimmed, else: nil
  end

  defp normalize_reasoning_effort(_), do: nil

  @valid_text_verbosities ~w(low medium high)
  defp normalize_text_verbosity(verbosity) when is_atom(verbosity) and not is_nil(verbosity),
    do: normalize_text_verbosity(Atom.to_string(verbosity))

  defp normalize_text_verbosity(verbosity) when is_binary(verbosity) do
    trimmed = String.trim(verbosity)
    if trimmed in @valid_text_verbosities, do: trimmed, else: nil
  end

  defp normalize_text_verbosity(_), do: nil

  # Fold canonical History events into Responses input items (ADR 0003). `model` is the
  # request model, used to guard reasoning-item replay (ADR 0007).
  defp fold_input(history, model, opts) do
    events = Compaction.provider_history(history)
    latest_user_index = latest_user_index(events)
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    events
    |> Enum.with_index()
    |> Enum.reduce(
      %{items: [], pending_calls: %{}, deferred_skill_activations: %{}},
      fn {event, index}, state ->
        fold_event(event, state, model, workspace,
          current_user?: latest_user_index == index,
          active_turn?: is_integer(latest_user_index) and index >= latest_user_index
        )
      end
    )
    |> close_orphan_tool_calls(model, workspace)
    |> Map.fetch!(:items)
  end

  defp fold_event(
         %{type: :tool_call, data: %{"call_id" => id}} = event,
         state,
         model,
         workspace,
         _opts
       ) do
    state =
      if map_size(state.deferred_skill_activations) > 0 do
        close_orphan_tool_calls(state, model, workspace)
      else
        state
      end

    items = to_input_item(event, model, workspace: workspace)

    state
    |> Map.update!(:items, &(&1 ++ items))
    |> Map.update!(:pending_calls, &Map.put(&1, id, event))
  end

  defp fold_event(
         %{type: :tool_result, data: %{"call_id" => id}} = event,
         state,
         model,
         workspace,
         opts
       ) do
    if Map.has_key?(state.pending_calls, id) do
      result_items =
        to_input_item(event, model,
          workspace: workspace,
          resource_view_rehydrate?: Keyword.get(opts, :active_turn?, false)
        )

      {activations, deferred_skill_activations} =
        Map.pop(state.deferred_skill_activations, id, [])

      activation_items =
        Enum.flat_map(activations, &to_input_item(&1, model, workspace: workspace))

      state
      |> Map.update!(:items, &(&1 ++ result_items ++ activation_items))
      |> Map.update!(:pending_calls, &Map.delete(&1, id))
      |> Map.put(:deferred_skill_activations, deferred_skill_activations)
    else
      state
    end
  end

  defp fold_event(%{type: :skill_activation} = event, state, model, workspace, opts) do
    case pending_skill_view_call_id(event, state.pending_calls) do
      {:ok, call_id} ->
        Map.update!(state, :deferred_skill_activations, fn deferred ->
          Map.update(deferred, call_id, [event], &(&1 ++ [event]))
        end)

      :error ->
        fold_non_tool_event(event, state, model, workspace, opts)
    end
  end

  defp fold_event(event, state, model, workspace, opts) do
    if map_size(state.pending_calls) > 0 and transparent_while_tool_pending?(event) do
      state
    else
      fold_non_tool_event(event, state, model, workspace, opts)
    end
  end

  defp fold_non_tool_event(event, state, model, workspace, opts) do
    state = close_orphan_tool_calls(state, model, workspace)

    Map.update!(
      state,
      :items,
      &(&1 ++
          to_input_item(event, model,
            workspace: workspace,
            current_user?: Keyword.get(opts, :current_user?, false)
          ))
    )
  end

  defp pending_skill_view_call_id(
         %{data: %{"name" => activation_name}},
         pending_calls
       )
       when is_binary(activation_name) do
    matching_call_ids =
      Enum.reduce(pending_calls, [], fn
        {call_id, %{data: %{"name" => "skill_view", "args" => args}}}, matches
        when is_map(args) ->
          path = Map.get(args, "path", "SKILL.md")

          if args["name"] == activation_name and is_binary(path) and Skills.main_file?(path) do
            [call_id | matches]
          else
            matches
          end

        _pending_call, matches ->
          matches
      end)

    case matching_call_ids do
      [call_id] -> {:ok, call_id}
      _zero_or_ambiguous -> :error
    end
  end

  defp pending_skill_view_call_id(_event, _pending_calls), do: :error

  defp transparent_while_tool_pending?(%{type: type})
       when type in [:permission_decision, :provider_usage, :subagent_event, :workflow_event],
       do: true

  defp transparent_while_tool_pending?(_event), do: false

  defp close_orphan_tool_calls(
         %{pending_calls: pending, deferred_skill_activations: deferred} = state,
         model,
         workspace
       )
       when map_size(pending) == 0 do
    activation_items = deferred_activation_items(deferred, model, workspace)

    %{
      state
      | items: state.items ++ activation_items,
        deferred_skill_activations: %{}
    }
  end

  defp close_orphan_tool_calls(
         %{items: items, pending_calls: pending, deferred_skill_activations: deferred} = state,
         model,
         workspace
       ) do
    pending_items =
      pending
      |> Enum.sort_by(fn {call_id, _event} -> call_id end)
      |> Enum.flat_map(fn {call_id, event} ->
        [orphan_tool_call_output(call_id, event)] ++
          activation_input_items(Map.get(deferred, call_id, []), model, workspace)
      end)

    remaining_activations =
      deferred
      |> Map.drop(Map.keys(pending))
      |> deferred_activation_items(model, workspace)

    %{
      state
      | items: items ++ pending_items ++ remaining_activations,
        pending_calls: %{},
        deferred_skill_activations: %{}
    }
  end

  defp orphan_tool_call_output(call_id, event) do
    %{
      "type" => "function_call_output",
      "call_id" => call_id,
      "output" =>
        Jason.encode!(%{
          ok: false,
          error: %{
            kind: "orphan_tool_call",
            message: "Pixir replay found a tool_call without a matching tool_result",
            details: %{
              call_id: call_id,
              tool: event.data["name"]
            }
          }
        })
    }
  end

  defp deferred_activation_items(deferred, model, workspace) do
    deferred
    |> Enum.sort_by(fn {call_id, _events} -> call_id end)
    |> Enum.flat_map(fn {_call_id, events} ->
      activation_input_items(events, model, workspace)
    end)
  end

  defp activation_input_items(events, model, workspace) do
    Enum.flat_map(events, &to_input_item(&1, model, workspace: workspace))
  end

  defp latest_user_index(events) do
    events
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {event, index} ->
      if event.type == :user_message, do: index
    end)
  end

  defp to_input_item(event, model, opts)

  defp to_input_item(%{type: :user_message, data: data} = event, _model, opts) do
    text = Map.get(data, "text", "")
    resources = Map.get(data, "resources", [])

    content =
      if Keyword.get(opts, :current_user?, false) do
        current_user_content(event.session_id, text, resources, opts)
      else
        replay_user_content(text, resources)
      end

    [%{"role" => "user", "content" => content}]
  end

  defp to_input_item(
         %{type: :assistant_message, data: %{"metadata" => %{"partial" => true}}},
         _model,
         _opts
       ),
       do: []

  defp to_input_item(%{type: :assistant_message, data: %{"text" => text}}, _model, _opts),
    do: [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]

  # Re-inject the opaque reasoning item verbatim (ADR 0007), but only when it was
  # produced by the current model — an encrypted item is invalid for a different model,
  # and dropping it is always safe. Pixir sends no `fc_` ids, so no pairing to neutralize.
  defp to_input_item(
         %{type: :reasoning, data: %{"item" => item, "model" => item_model} = data},
         model,
         _opts
       )
       when item_model == model do
    # Dialect guard (ADR 0037 D5): reasoning captured under a foreign provider
    # dialect never enters a Responses input array, even on a model-name match.
    # Absent dialect = pre-P5 OpenAI event, replays unchanged.
    case Map.get(data, "dialect", "openai") do
      "openai" -> [item]
      _foreign_dialect -> []
    end
  end

  defp to_input_item(%{type: :reasoning}, _model, _opts), do: []

  defp to_input_item(%{type: :skill_activation, data: data}, _model, _opts) do
    [
      %{
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => Skills.render_activation(data)}]
      }
    ]
  end

  defp to_input_item(%{type: :subagent_event, data: %{"event" => event} = data}, _model, _opts)
       when event in ["finished", "failed", "cancelled", "timed_out"] do
    text =
      "Subagent #{data["subagent_id"]} (#{data["agent"]}) #{data["status"]}: " <>
        (data["summary"] || "") <>
        Pixir.Provider.OutputTruncationSummary.child_context_suffix(data)

    [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}]
  end

  defp to_input_item(%{type: :subagent_event}, _model, _opts), do: []

  defp to_input_item(%{type: :workflow_event}, _model, _opts), do: []

  defp to_input_item(%{type: :history_compaction, data: data}, _model, _opts) do
    [
      %{
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => Compaction.render_for_provider(data)}]
      }
    ]
  end

  defp to_input_item(%{type: :branch_summary, data: data}, _model, _opts) do
    [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => BranchSummary.render_for_provider(data)}
        ]
      }
    ]
  end

  defp to_input_item(%{type: :provider_usage}, _model, _opts), do: []

  defp to_input_item(%{type: :turn_failed}, _model, _opts), do: []

  defp to_input_item(
         %{type: :tool_call, data: %{"call_id" => id, "name" => name} = data},
         _model,
         _opts
       ),
       do: [
         %{
           "type" => "function_call",
           "call_id" => id,
           "name" => name,
           "arguments" => Jason.encode!(data["args"] || %{})
         }
       ]

  defp to_input_item(%{type: :tool_result, data: %{"call_id" => id} = data} = event, _model, opts) do
    output = %{
      "type" => "function_call_output",
      "call_id" => id,
      "output" => tool_output_text(data)
    }

    if Keyword.get(opts, :resource_view_rehydrate?, false) do
      case resource_view_item(event.session_id, data, opts) do
        nil -> [output]
        item -> [output, item]
      end
    else
      [output]
    end
  end

  defp to_input_item(_other, _model, _opts), do: []

  defp current_user_content(session_id, text, resources, opts) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())
    text_resources = Enum.reject(List.wrap(resources), &match?(%{"kind" => "image"}, &1))
    text = text_with_resource_descriptors(text, text_resources)

    [%{"type" => "input_text", "text" => text}]
    |> Kernel.++(input_images(session_id, resources, workspace))
  end

  defp text_with_resource_descriptors(text, []), do: text

  defp text_with_resource_descriptors(text, resources) do
    text <> "\n\nAttached resources:\n" <> Pixir.SessionResources.render_descriptors(resources)
  end

  defp replay_user_content(text, resources) when is_list(resources) and resources != [] do
    descriptor_text = Pixir.SessionResources.render_descriptors(resources)
    [%{"type" => "input_text", "text" => text <> "\n\nAttached resources:\n" <> descriptor_text}]
  end

  defp replay_user_content(text, _resources),
    do: [%{"type" => "input_text", "text" => text}]

  defp input_images(session_id, resources, workspace) when is_list(resources) do
    resources
    |> Enum.flat_map(fn
      %{"kind" => "image"} = descriptor ->
        case Pixir.SessionResources.data_url(session_id, descriptor, workspace: workspace) do
          {:ok, data_url} ->
            [
              %{
                "type" => "input_image",
                "image_url" => data_url,
                "detail" => descriptor["detail"] || "auto"
              }
            ]

          {:error, error} ->
            [
              %{
                "type" => "input_text",
                "text" =>
                  "Image resource #{descriptor["resource_id"]} could not be rehydrated: " <>
                    tool_output_text(%{"error" => error})
              }
            ]
        end

      _other ->
        []
    end)
  end

  defp input_images(_session_id, _resources, _workspace), do: []

  defp resource_view_item(session_id, %{"resource_view" => %{"descriptor" => descriptor}}, opts)
       when is_map(descriptor) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    content =
      [
        %{
          "type" => "input_text",
          "text" =>
            "Resource view requested:\n" <> Pixir.SessionResources.render_descriptor(descriptor)
        }
      ] ++ input_images(session_id, [descriptor], workspace)

    %{"role" => "user", "content" => content}
  end

  defp resource_view_item(_session_id, _data, _opts), do: nil

  defp tool_output_text(%{"output" => output}) when is_binary(output), do: output
  defp tool_output_text(data), do: Jason.encode!(Map.drop(data, ["call_id"]))

  defp run(_request, opts, http_request, init) do
    transport_label = StreamIdle.transport_label(opts)

    StreamIdle.run(
      fn notify ->
        opts = Keyword.put(opts, :stream_activity, notify)

        chunk =
          fn chunk, acc ->
            notify.()
            handle_chunk(chunk, acc)
          end

        if Keyword.has_key?(opts, :transport) do
          transport = Keyword.get(opts, :transport, FinchTransport)
          run_transport(transport, http_request, init, chunk)
        else
          TransportPolicy.stream(http_request, init, chunk, opts)
        end
      end,
      opts,
      transport_label
    )
  end

  defp run_transport(transport, http_request, init, fun) when is_function(transport, 3),
    do: transport.(http_request, init, fun)

  defp run_transport(transport, http_request, init, fun),
    do: transport.stream(http_request, init, fun)

  # ── streaming reducer ─────────────────────────────────────────────────────

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:metadata, metadata}, acc) when is_map(metadata),
    do: %{acc | provider_metadata: Map.merge(acc.provider_metadata, metadata)}

  defp handle_chunk({:data, data}, %{status: status} = acc) when status in 200..299,
    do: feed_sse(acc, data)

  defp handle_chunk({:data, data}, acc), do: %{acc | err_body: ErrBody.append(acc.err_body, data)}

  defp feed_sse(%{backend_mode: :open_responses} = acc, data), do: feed_open_sse(acc, data)

  defp feed_sse(acc, data) do
    buffer = acc.buffer <> data
    blocks = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(blocks, -1)
    Enum.reduce(complete, %{acc | buffer: rest}, &apply_sse_block/2)
  end

  defp feed_open_sse(%{sse_decoder: decoder} = acc, data) do
    case SSEDecoder.feed(decoder, data) do
      {:ok, decoder, frames} ->
        acc
        |> Map.put(:sse_decoder, decoder)
        |> apply_open_frames(frames)

      {:error, decoder, frames, error} ->
        acc
        |> Map.put(:sse_decoder, decoder)
        |> apply_open_frames(frames)
        |> put_open_stream_error(error)
    end
  end

  defp finish_sse(%{backend_mode: :chatgpt_codex} = acc), do: acc

  defp finish_sse(%{backend_mode: :open_responses, sse_decoder: decoder} = acc) do
    acc =
      case SSEDecoder.finish(decoder) do
        {:ok, decoder, frames, summary} ->
          acc
          |> Map.put(:sse_decoder, decoder)
          |> apply_open_frames(frames)
          |> put_open_decoder_summary(summary)

        {:error, decoder, error} ->
          acc
          |> Map.put(:sse_decoder, decoder)
          |> put_open_stream_error(error)
      end

    put_open_event_summary(acc)
  end

  defp apply_open_frames(acc, frames) do
    Enum.reduce(frames, acc, fn
      :done, current -> %{current | open_done: true}
      frame, current -> apply_open_frame(frame, current)
    end)
  end

  defp apply_open_frame(%{event: event_type, data: payload, ordinal: ordinal}, acc) do
    case Jason.decode(payload) do
      {:ok, %{"type" => body_type} = event} when is_binary(body_type) ->
        cond do
          not is_nil(acc.stream_error) ->
            acc

          event_type != body_type ->
            acc
            |> Map.put(:open_event_type_match, false)
            |> put_open_stream_error(open_event_error(:event_type_mismatch, ordinal))

          not is_nil(acc.terminal_event_type) ->
            put_open_stream_error(acc, semantic_after_terminal_error(body_type, ordinal))

          true ->
            case ResponsesExtensions.validate_stream_event(event) do
              {:ok, :known} ->
                acc
                |> count_open_event(body_type)
                |> apply_open_event(event)

              {:ok, :unknown} ->
                count_unknown_open_event(acc)

              {:unsupported, capability} ->
                put_open_stream_error(
                  acc,
                  unsupported_open_stream_capability(capability, ordinal)
                )

              {:error, reason} ->
                put_open_stream_error(
                  acc,
                  open_event_error(reason, ordinal, body_type)
                )
            end
        end

      {:ok, _invalid_shape} ->
        put_open_stream_error(acc, open_event_error(:invalid_event_shape, ordinal))

      {:error, _decode_error} ->
        put_open_stream_error(acc, open_event_error(:malformed_json, ordinal))
    end
  end

  @known_open_event_types MapSet.new([
                            "error",
                            "response.created",
                            "response.in_progress",
                            "response.queued",
                            "response.output_item.added",
                            "response.output_item.done",
                            "response.content_part.added",
                            "response.content_part.done",
                            "response.output_text.delta",
                            "response.output_text.done",
                            "response.output_text.annotation.added",
                            "response.function_call_arguments.delta",
                            "response.function_call_arguments.done",
                            "response.refusal.delta",
                            "response.refusal.done",
                            "response.reasoning.delta",
                            "response.reasoning.done",
                            "response.reasoning_summary_part.added",
                            "response.reasoning_summary_part.done",
                            "response.reasoning_summary_text.delta",
                            "response.reasoning_summary_text.done",
                            "response.completed",
                            "response.incomplete",
                            "response.failed"
                          ])

  defp count_open_event(acc, type) do
    Map.update!(acc, :open_event_counts, &Map.update(&1, type, 1, fn count -> count + 1 end))
  end

  defp count_unknown_open_event(acc),
    do:
      Map.update!(acc, :open_event_counts, &Map.update(&1, "other", 1, fn count -> count + 1 end))

  defp open_event_error(reason, ordinal, event_type \\ nil) do
    details = %{reason: reason, ordinal: ordinal}

    details =
      if is_binary(event_type), do: Map.put(details, :event_type, event_type), else: details

    err(:invalid_response, "The Open Responses stream event was invalid.", details)
  end

  defp semantic_after_terminal_error(type, _ordinal)
       when type in ["response.completed", "response.incomplete", "response.failed"],
       do: terminal_conflict_error()

  defp semantic_after_terminal_error(type, ordinal) do
    if MapSet.member?(@known_open_event_types, type),
      do: open_event_error(:semantic_event_after_terminal, ordinal, type),
      else: open_event_error(:semantic_event_after_terminal, ordinal)
  end

  defp apply_open_event(acc, %{"type" => "error", "error" => error}) do
    put_open_in_band_error(acc, "error", error)
  end

  defp apply_open_event(
         acc,
         %{"type" => "response.failed", "response" => %{"error" => error}}
       ) do
    acc
    |> Map.put(:terminal_event_type, "response.failed")
    |> put_open_in_band_error("response.failed", error)
  end

  defp apply_open_event(acc, %{"type" => "response.output_text.done"}), do: acc

  defp apply_open_event(
         acc,
         %{"type" => "response.output_item.done", "item" => %{"type" => "message"}}
       ),
       do: acc

  defp apply_open_event(acc, event), do: apply_event({:ok, event}, acc)

  defp put_open_in_band_error(%{stream_error: nil, status: status} = acc, event_type, error) do
    type = safe_error_field(error, "type")
    code = safe_error_field(error, "code")
    remote_message = safe_error_field(error, "message")

    kind =
      if stream_context_overflow?(type, code, remote_message),
        do: :context_overflow,
        else: :provider_http_error

    details = %{
      status: status,
      event_type: event_type,
      remote_error_class: safe_remote_error_class(kind, type, code),
      remote_field_count: if(is_map(error), do: min(map_size(error), 16), else: 0),
      remote_message_bytes:
        if(is_binary(remote_message), do: min(byte_size(remote_message), 1_000_000), else: 0)
    }

    details = maybe_retryable_stream_error_details(kind, type, code, details)

    message =
      if kind == :context_overflow,
        do: "The Open Responses request exceeded the Provider context limit.",
        else: "The Open Responses stream reported a Provider failure."

    %{acc | stream_error: err(kind, message, details)}
  end

  defp put_open_in_band_error(acc, _event_type, _error), do: acc

  defp safe_error_field(error, field) when is_map(error), do: Map.get(error, field)
  defp safe_error_field(_error, _field), do: nil

  defp safe_remote_error_class(:context_overflow, _type, _code), do: :context_overflow

  defp safe_remote_error_class(_kind, type, code) do
    if transient_stream_error?(type, code), do: :transient, else: :provider_failure
  end

  defp unsupported_open_stream_capability(capability, ordinal) do
    err(
      :unsupported_backend_capability,
      "The Open Responses stream returned an unsupported backend capability.",
      %{backend_mode: :open_responses, capability: capability, ordinal: ordinal}
    )
  end

  defp put_open_stream_error(%{stream_error: nil} = acc, error) do
    %{acc | stream_error: attach_terminal_audit(error, acc)}
  end

  defp put_open_stream_error(acc, _error), do: acc

  defp attach_terminal_audit(error, %{terminal_evidence: nil}), do: error

  defp attach_terminal_audit(%{error: %{details: details} = inner} = error, acc) do
    audit = %{
      terminal_event_type: acc.terminal_event_type,
      terminal_summary: OutputTruncation.to_result_map(acc.terminal_evidence)
    }

    %{error | error: %{inner | details: Map.merge(details, audit)}}
  end

  defp put_open_decoder_summary(acc, summary) do
    metadata =
      Map.put(acc.provider_metadata, "open_responses_decoder", %{
        "done" => summary.done,
        "discarded_pending" => summary.discarded_pending,
        "discarded_bytes" => summary.discarded_bytes
      })

    %{acc | provider_metadata: metadata}
  end

  defp put_open_event_summary(acc) do
    metadata =
      Map.put(acc.provider_metadata, "open_responses", %{
        "known_event_counts" => acc.open_event_counts,
        "event_type_match" => acc.open_event_type_match,
        "done" => acc.open_done
      })

    %{acc | provider_metadata: metadata}
  end

  defp apply_sse_block(block, acc) do
    payload =
      block
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.replace_prefix("data:", "") |> String.trim_leading()
      end)

    cond do
      payload == "" or payload == "[DONE]" -> acc
      true -> apply_event(Jason.decode(payload), acc)
    end
  end

  defp apply_event({:ok, %{"type" => "response.output_text.delta", "delta" => delta}}, acc)
       when is_binary(delta) do
    acc.on_delta.({:text_delta, delta})
    %{acc | text: acc.text <> delta}
  end

  defp apply_event({:ok, %{"type" => "error", "error" => error}}, acc) when is_map(error) do
    put_stream_error(acc, "error", error)
  end

  defp apply_event(
         {:ok, %{"type" => "response.failed", "response" => %{"error" => error}}},
         acc
       )
       when is_map(error) do
    put_stream_error(acc, "response.failed", error)
  end

  defp apply_event({:ok, %{"type" => type, "delta" => delta}}, acc)
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] and
              is_binary(delta) do
    acc.on_delta.({:reasoning_delta, delta})
    %{acc | reasoning: acc.reasoning <> delta}
  end

  defp apply_event(
         {:ok,
          %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item}},
         acc
       ) do
    case ToolCall.from_json(item["call_id"], item["name"], item["arguments"]) do
      {:ok, call} -> %{acc | output_items: [{:function_call, call} | acc.output_items]}
      {:error, error} -> %{acc | stream_error: acc.stream_error || error}
    end
  end

  defp apply_event(
         {:ok,
          %{
            "type" => "response.output_item.done",
            "item" => %{"type" => "web_search_call"} = item
          }},
         acc
       ) do
    call = compact_web_search_call(item)

    acc
    |> append_web_search("calls", [call])
    |> append_web_search("sources", web_search_sources(item))
    |> Map.update!(:output_items, &[{:provider_hosted_tool, call} | &1])
  end

  defp apply_event(
         {:ok, %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item}},
         acc
       ) do
    append_web_search(acc, "annotations", message_annotations(item))
  end

  defp apply_event({:ok, %{"type" => "response.output_text.done"} = event}, acc) do
    append_web_search(acc, "annotations", message_annotations(event))
  end

  # Capture the encrypted reasoning item (`rs_…`) opaquely (ADR 0007). The item carries
  # `encrypted_content` and its own id; we store it verbatim and never interpret it.
  defp apply_event(
         {:ok,
          %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning"} = item}},
         acc
       ) do
    %{acc | output_items: [{:reasoning, item} | acc.output_items]}
  end

  defp apply_event({:ok, %{"type" => type} = event}, acc)
       when type in ["response.completed", "response.incomplete"] do
    {usage, evidence} =
      case terminal_response(event) do
        {:ok, response} ->
          {terminal_usage(response, event), openai_terminal_evidence(event, response)}

        :invalid ->
          {safe_event_usage(event), OutputTruncation.unknown(:invalid_evidence)}
      end

    acc
    |> Map.put(:terminal_event_type, type)
    |> maybe_put_usage(usage)
    |> put_terminal_evidence(evidence)
  end

  defp apply_event({:ok, %{"type" => type} = event}, acc) when is_binary(type) do
    if String.starts_with?(type, "response.web_search_call.") do
      append_web_search(acc, "events", [compact_web_search_event(event)])
    else
      acc
    end
  end

  defp apply_event(_other, acc), do: acc

  defp put_stream_error(%{stream_error: nil, status: status} = acc, event_type, error) do
    message = error["message"] || "Responses stream failed."
    type = error["type"] || ""
    code = error["code"] || ""

    # ADR 0020: in-band stream errors (e.g. `response.failed` over a 200 SSE
    # stream or the WebSocket transport) carry overflow rejections too. Unlike
    # HTTP classification, this path has no status guard, so message-only matches
    # are accepted only for provider/context-shaped error families.
    kind =
      if stream_context_overflow?(type, code, error["message"]) do
        :context_overflow
      else
        :provider_http_error
      end

    %{
      acc
      | stream_error:
          err(
            kind,
            message,
            maybe_retryable_stream_error_details(kind, type, code, %{
              status: status,
              event_type: event_type,
              code: error["code"],
              type: error["type"],
              param: error["param"]
            })
          )
    }
  end

  defp put_stream_error(acc, _event_type, _error), do: acc

  defp maybe_retryable_stream_error_details(:provider_http_error, type, code, details) do
    if transient_stream_error?(type, code) do
      Map.put(details, :retryable, true)
    else
      details
    end
  end

  defp maybe_retryable_stream_error_details(_kind, _type, _code, details), do: details

  # #278: mirror the Anthropic in-band classifier precedent by stamping retryable
  # once at the stream-error source; retry layers only read this classification.
  @transient_stream_errors ~w(server_is_overloaded service_unavailable_error server_error
                              overloaded rate_limit_exceeded too_many_requests)
  defp transient_stream_error?(type, code) do
    type in @transient_stream_errors or code in @transient_stream_errors
  end

  defp maybe_put_usage(acc, usage) when is_map(usage),
    do: %{acc | usage: usage, usage_summary: usage_summary(usage)}

  defp maybe_put_usage(acc, _usage), do: acc

  defp put_terminal_evidence(%{terminal_evidence: nil} = acc, evidence),
    do: %{acc | terminal_evidence: evidence}

  defp put_terminal_evidence(%{terminal_evidence: existing} = acc, evidence) do
    if OutputTruncation.to_result_map(existing) == OutputTruncation.to_result_map(evidence) do
      acc
    else
      %{acc | stream_error: acc.stream_error || terminal_conflict_error()}
    end
  end

  defp terminal_conflict_error do
    err(:invalid_response, "Responses stream contained conflicting terminal evidence.", %{
      field: :terminal_lifecycle
    })
  end

  defp openai_terminal_evidence(%{"type" => "response.completed"} = event, response) do
    case {authoritative_incomplete_details(response, event), response["status"]} do
      {:invalid, _status} ->
        OutputTruncation.unknown(:invalid_evidence)

      {{:ok, details}, _status} ->
        incomplete_evidence(response, event, details)

      {:absent, "incomplete"} ->
        incomplete_evidence(response, event, %{})

      {:absent, _status} ->
        OutputTruncation.not_truncated("response.completed")
    end
  end

  defp openai_terminal_evidence(%{"type" => "response.incomplete"} = event, response) do
    case authoritative_incomplete_details(response, event) do
      :invalid -> OutputTruncation.unknown(:invalid_evidence)
      {:ok, details} -> incomplete_evidence(response, event, details)
      :absent -> incomplete_evidence(response, event, %{})
    end
  end

  defp incomplete_evidence(response, event, details) do
    reason = authoritative_reason(details, response, event)

    case reason do
      value when value in ["max_output_tokens", "max_tokens"] ->
        OutputTruncation.truncated(:provider_output_limit, value)

      "content_filter" ->
        OutputTruncation.truncated(:provider_content_filter, "content_filter")

      nil ->
        OutputTruncation.unknown(:missing_terminal_evidence, "response.incomplete")

      value when is_binary(value) ->
        evidence = OutputTruncation.unknown(:unrecognized_terminal_reason, value)

        if OutputTruncation.reason(evidence) == :invalid_evidence do
          OutputTruncation.unknown(:invalid_evidence)
        else
          evidence
        end

      _ ->
        OutputTruncation.unknown(:invalid_evidence)
    end
  end

  defp terminal_response(event) do
    case Map.get(event, "response") do
      nil -> {:ok, %{}}
      response when is_map(response) -> {:ok, response}
      _malformed -> :invalid
    end
  end

  # Nested usage is authoritative when present. A missing/nil nested value may use the
  # event-level usage map; malformed nested usage is ignored rather than falling around it.
  defp terminal_usage(response, event) do
    case Map.get(response, "usage") do
      usage when is_map(usage) -> usage
      nil -> safe_event_usage(event)
      _malformed -> nil
    end
  end

  defp safe_event_usage(event) do
    case Map.get(event, "usage") do
      usage when is_map(usage) -> usage
      _missing_or_malformed -> nil
    end
  end

  defp authoritative_incomplete_details(response, event) do
    case map_field(response, "incomplete_details") do
      :absent -> map_field(event, "incomplete_details")
      authoritative -> authoritative
    end
  end

  defp map_field(map, key) do
    if Map.has_key?(map, key) do
      case Map.get(map, key) do
        nil -> :absent
        value when is_map(value) -> {:ok, value}
        _malformed -> :invalid
      end
    else
      :absent
    end
  end

  defp authoritative_reason(details, response, event) do
    case value_field(details, "reason") do
      :absent ->
        case value_field(response, "reason") do
          :absent -> value_field(event, "reason") |> absent_to_nil()
          value -> value
        end

      value ->
        value
    end
  end

  defp value_field(map, key) do
    if Map.has_key?(map, key) and not is_nil(Map.get(map, key)),
      do: Map.get(map, key),
      else: :absent
  end

  defp absent_to_nil(:absent), do: nil
  defp absent_to_nil(value), do: value

  defp compact_web_search_call(item) do
    %{
      "type" => "web_search_call",
      "id" => safe_string(item["id"] || item["call_id"], 160),
      "status" => safe_string(item["status"], 80),
      "action" => compact_web_search_action(item["action"])
    }
    |> drop_nil_values()
  end

  defp compact_web_search_event(event) do
    %{
      "type" => safe_string(event["type"], 120),
      "id" => safe_string(event["id"] || event["item_id"] || event["output_index"], 160),
      "status" => safe_string(event["status"], 80),
      "action" => compact_web_search_action(event["action"])
    }
    |> drop_nil_values()
  end

  defp compact_web_search_action(action) when is_map(action) do
    %{
      "type" => safe_string(action["type"], 80),
      "query_present" => web_search_query_present(action["query"]),
      "query_length" => web_search_query_length(action["query"]),
      "sources" => web_search_sources(%{"action" => action})
    }
    |> drop_nil_values()
  end

  defp compact_web_search_action(_action), do: nil

  defp web_search_query_present(nil), do: nil
  defp web_search_query_present(_query), do: true

  defp web_search_query_length(query) when is_binary(query), do: String.length(query)
  defp web_search_query_length(_query), do: nil

  defp web_search_sources(%{"action" => %{"sources" => sources}}) when is_list(sources) do
    sources
    |> Enum.map(&normalize_source/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.take(20)
  end

  defp web_search_sources(_item), do: []

  defp normalize_source(source) when is_map(source) do
    %{
      "type" => safe_string(source["type"], 80),
      "url" => safe_string(source["url"], 1_000),
      "title" => safe_string(source["title"], 500)
    }
    |> drop_nil_values()
  end

  defp normalize_source(_source), do: %{}

  defp message_annotations(%{"annotations" => annotations}) when is_list(annotations),
    do: normalize_annotations(annotations)

  defp message_annotations(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"annotations" => annotations} when is_list(annotations) ->
        normalize_annotations(annotations)

      _other ->
        []
    end)
  end

  defp message_annotations(_item), do: []

  defp normalize_annotations(annotations) do
    annotations
    |> Enum.map(&normalize_annotation/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.take(50)
  end

  defp normalize_annotation(%{"type" => "url_citation", "url_citation" => citation}) do
    normalize_annotation(Map.put(citation || %{}, "type", "url_citation"))
  end

  defp normalize_annotation(%{"type" => "url_citation"} = annotation) do
    %{
      "type" => "url_citation",
      "url" => safe_string(annotation["url"], 1_000),
      "title" => safe_string(annotation["title"], 500),
      "start_index" => safe_int(annotation["start_index"]),
      "end_index" => safe_int(annotation["end_index"])
    }
    |> drop_nil_values()
  end

  defp normalize_annotation(_annotation), do: %{}

  defp append_web_search(acc, _key, []), do: acc

  defp append_web_search(acc, key, values)
       when key in ["events", "calls", "annotations", "sources"] do
    max =
      case key do
        "events" -> 50
        "calls" -> 20
        "annotations" -> 50
        "sources" -> 20
      end

    update_in(acc.provider_hosted_tools, ["web_search", key], fn existing ->
      existing
      |> List.wrap()
      |> Kernel.++(values)
      |> dedupe_maps()
      |> Enum.take(max)
    end)
    |> then(&%{acc | provider_hosted_tools: &1})
  end

  defp finalize_hosted_tools(%{"web_search" => web_search}) do
    web_search =
      web_search
      |> Map.put("call_count", length(web_search["calls"] || []))
      |> Map.put("annotation_count", length(web_search["annotations"] || []))
      |> Map.put("source_count", length(web_search["sources"] || []))

    if web_search["call_count"] == 0 and web_search["annotation_count"] == 0 and
         web_search["source_count"] == 0 and Enum.empty?(web_search["events"] || []) do
      %{}
    else
      %{"web_search" => web_search}
    end
  end

  defp finalize_hosted_tools(_hosted_tools), do: %{}

  defp dedupe_maps(items), do: Enum.uniq_by(items, &Jason.encode!/1)

  defp safe_string(value, max) when is_binary(value) do
    value
    |> String.replace_invalid()
    |> take_graphemes(max)
  end

  defp safe_string(value, max) when is_integer(value),
    do: safe_string(Integer.to_string(value), max)

  defp safe_string(_value, _max), do: nil

  defp safe_int(value) when is_integer(value), do: value

  defp safe_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp safe_int(_value), do: nil

  defp take_graphemes(text, max) do
    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "…"
    end
  end

  defp drop_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end

  defp finalize(%{status: status, stream_error: error})
       when status in 200..299 and not is_nil(error),
       do: {:error, error}

  defp finalize(%{status: status} = acc) when status in 200..299 do
    output_items = Enum.reverse(acc.output_items)
    calls = for {:function_call, call} <- output_items, do: call
    reasoning_items = for {:reasoning, item} <- output_items, do: item
    provider_hosted_tools = finalize_hosted_tools(acc.provider_hosted_tools)
    web_search = Map.get(provider_hosted_tools, "web_search", %{})

    {:ok,
     %{
       text: acc.text,
       reasoning: acc.reasoning,
       reasoning_items: reasoning_items,
       function_calls: calls,
       output_items: output_items,
       provider_hosted_tools: provider_hosted_tools,
       web_search: web_search,
       usage: acc.usage,
       usage_summary: acc.usage_summary,
       provider_metadata: acc.provider_metadata,
       finish_reason: if(calls == [], do: :stop, else: :tool_calls),
       output_truncation:
         acc.terminal_evidence || OutputTruncation.unknown(:missing_terminal_evidence)
     }}
  end

  defp finalize(acc) do
    body = ErrBody.body(acc.err_body)
    {:error, classify_http_error(acc.status, body, ErrBody.truncated?(acc.err_body))}
  end

  @doc """
  Normalize OpenAI usage payloads into the fields Pixir records as Provider evidence.

  Supports the Responses shape (`input_tokens_details.cached_tokens`) and the legacy
  prompt/completion naming used by older examples.
  """
  @spec usage_summary(map() | nil) :: map()
  def usage_summary(nil), do: usage_summary(%{})

  def usage_summary(usage) when is_map(usage) do
    input_tokens =
      int(first(usage, ["input_tokens", "prompt_tokens", :input_tokens, :prompt_tokens]))

    cached_tokens =
      int(
        first_nested(usage, [
          ["input_tokens_details", "cached_tokens"],
          ["prompt_tokens_details", "cached_tokens"],
          [:input_tokens_details, :cached_tokens],
          [:prompt_tokens_details, :cached_tokens]
        ])
      )

    output_tokens =
      int(
        first(usage, ["output_tokens", "completion_tokens", :output_tokens, :completion_tokens])
      )

    reasoning_tokens =
      int(
        first_nested(usage, [
          ["output_tokens_details", "reasoning_tokens"],
          ["completion_tokens_details", "reasoning_tokens"],
          [:output_tokens_details, :reasoning_tokens],
          [:completion_tokens_details, :reasoning_tokens]
        ])
      )

    total_tokens =
      int(first(usage, ["total_tokens", :total_tokens])) ||
        (input_tokens || 0) + (output_tokens || 0)

    %{
      input_tokens: input_tokens || 0,
      cached_tokens: cached_tokens || 0,
      output_tokens: output_tokens || 0,
      reasoning_tokens: reasoning_tokens || 0,
      total_tokens: total_tokens,
      cache_hit_rate: cache_hit_rate(cached_tokens, input_tokens),
      cache: %{"creation_tokens" => 0, "read_tokens" => cached_tokens || 0}
    }
  end

  defp first(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp first_nested(map, paths) do
    Enum.find_value(paths, fn path ->
      case get_in(map, path) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: round(value)

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp cache_hit_rate(cached_tokens, input_tokens)
       when is_integer(cached_tokens) and is_integer(input_tokens) and input_tokens > 0,
       do: cached_tokens / input_tokens

  defp cache_hit_rate(_cached_tokens, _input_tokens), do: nil

  # Parse the error body and assign a stable `kind` (ADR 0005), mirroring Pi's
  # handling of usage/rate limits and unsupported models.
  defp classify_http_error(status, body, truncated?) do
    error = do_classify_http_error(status, body)

    if truncated? do
      update_in(error, [:error, :details], &Map.put(&1, :err_body_truncated, true))
    else
      error
    end
  end

  defp do_classify_http_error(status, body) do
    error = parse_error_body(body)
    type = error["type"] || ""
    code = error["code"] || ""
    signature = type <> " " <> code
    message = error["message"]

    cond do
      signature =~ ~r/usage_limit_reached|usage_not_included/i ->
        err(:usage_limit_reached, usage_message(error), usage_details(status, error))

      status == 429 or signature =~ ~r/rate_limit_exceeded|too_many_requests/i ->
        err(
          :rate_limited,
          "rate limited by the Responses API (transient)",
          usage_details(status, error)
        )

      context_overflow?(status, type, code, message) ->
        err(
          :context_overflow,
          message || "the request exceeds the model context window",
          %{status: status, type: error["type"], code: error["code"]}
        )

      status == 400 and is_binary(message) and
          message =~ ~r/model.*(not supported|not available|does not exist)/i ->
        err(:model_not_supported, message, %{status: status})

      true ->
        err(:provider_http_error, message || "Responses API returned an error", %{
          status: status,
          body: body
        })
    end
  end

  # ADR 0020: a context/window-exceeded rejection gets its own stable kind so the
  # Turn loop can run overflow recovery (it would otherwise drown in the generic
  # :provider_http_error and recovery could never fire). Representative shapes:
  # the `context_length_exceeded` error code, and 400/413 invalid-request bodies
  # whose message names the context window / maximum context length / too-long
  # input. Terminal: `retryable?/1` never retries it.
  defp context_overflow?(status, type, code, message) do
    status in [400, 413] and
      (overflow_code_or_type?(type) or overflow_code_or_type?(code) or overflow_message?(message))
  end

  defp stream_context_overflow?(type, code, message) do
    overflow_code_or_type?(type) or overflow_code_or_type?(code) or
      (stream_context_error_family?(type, code) and overflow_message?(message))
  end

  defp stream_context_error_family?(type, code) do
    type in ["invalid_request_error", "bad_request", "request_too_large"] or
      code in ["invalid_request_error", "bad_request", "request_too_large"]
  end

  defp overflow_code_or_type?(value) when is_binary(value),
    do: value =~ ~r/context_length_exceeded|context_window_exceeded/i

  defp overflow_code_or_type?(_value), do: false

  defp overflow_message?(message) when is_binary(message),
    do:
      message =~
        ~r/context (length|window)|maximum context|exceeds the context|input is too long|prompt is too long/i

  defp overflow_message?(_message), do: false

  defp parse_error_body(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      {:ok, %{"detail" => detail}} when is_binary(detail) -> %{"message" => detail}
      _ -> %{}
    end
  end

  defp usage_message(error) do
    plan = if error["plan_type"], do: " (#{String.downcase(error["plan_type"])} plan)", else: ""

    when_ =
      case reset_minutes(error) do
        nil -> ""
        mins -> " Try again in ~#{mins} min."
      end

    "You have hit your ChatGPT usage limit#{plan}.#{when_}"
  end

  defp usage_details(status, error) do
    %{
      status: status,
      type: error["type"] || error["code"],
      plan_type: error["plan_type"],
      resets_at: error["resets_at"],
      resets_in_seconds: error["resets_in_seconds"]
    }
  end

  defp reset_minutes(%{"resets_at" => ts}) when is_integer(ts),
    do: max(0, round((ts * 1000 - System.system_time(:millisecond)) / 60_000))

  defp reset_minutes(%{"resets_in_seconds" => secs}) when is_integer(secs),
    do: max(0, div(secs, 60))

  defp reset_minutes(_error), do: nil

  defp err(kind, message, details),
    do: %{ok: false, error: %{kind: kind, message: message, details: details}}
end
