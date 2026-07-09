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
  :http_sse`) so WebSocket can be preferred while HTTP/SSE remains fallback.
  """

  alias Pixir.{BranchSummary, Compaction, Config, Event, Skills}
  alias Pixir.Provider.{FinchTransport, HostedTools, StreamIdle, TransportPolicy}

  @default_base_url "https://chatgpt.com/backend-api"
  @default_model "gpt-5.5"

  # The built-in model catalog (ADR 0009 / epic A.5). The same OpenAI/Codex
  # family the client may pick from; a `~/.pixir/config.json` `"models"` array
  # overrides/extends it. The default (the active `default_model/0`) is flagged
  # so the client's picker can mark it. Used to advertise the catalog over ACP
  # and to reject an unknown per-turn `_meta.model` early (`-32602`).
  @built_in_models ~w(
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
          provider_metadata: map()
        }

  @doc """
  Stream one Responses call, retrying transient failures (network, `:rate_limited`,
  5xx) with capped exponential backoff. Terminal errors (`:usage_limit_reached`,
  `:model_not_supported`, auth) are not retried. See the module doc for the result
  shape. Options: `:max_retries` (default 2), `:sleep` (injectable for tests).
  """
  @spec stream(request(), keyword()) :: {:ok, result()} | {:error, map()}
  def stream(request, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, Config.max_retries())
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    attempt(request, opts, 0, max_retries, sleep)
  end

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

  defp retryable?(%{error: %{kind: :provider_http_error, details: %{status: status}}})
       when status in [500, 502, 503, 504], do: true

  defp retryable?(_error), do: false

  defp do_stream(request, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    auth = Keyword.get(opts, :auth, Pixir.Auth)
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = request[:model] || Keyword.get(opts, :model) || default_model()

    reasoning_effort =
      normalize_reasoning_effort(
        request[:reasoning_effort] || opts[:reasoning_effort] || Config.reasoning_effort()
      )

    text_verbosity =
      normalize_text_verbosity(
        request[:text_verbosity] || opts[:text_verbosity] || Config.text_verbosity()
      )

    with {:ok, body} <- build_body(model, request, reasoning_effort, text_verbosity, base_url),
         {:ok, auth_headers} <- Pixir.Auth.request_headers(auth) do
      http_request = %{
        method: :post,
        url: resolve_url(base_url),
        headers: base_headers() ++ auth_headers,
        body: Jason.encode!(body)
      }

      init = %{
        status: nil,
        buffer: "",
        err_body: "",
        text: "",
        reasoning: "",
        stream_error: nil,
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
          finalize(acc)

        {:error, reason, acc} ->
          if structured_error?(reason) do
            {:error, reason}
          else
            {:error,
             err(:network, "provider stream failed", %{
               reason: inspect(reason),
               status: acc.status
             })}
          end

        {:error, reason} ->
          if structured_error?(reason) do
            {:error, reason}
          else
            {:error, err(:network, "provider stream failed", %{reason: inspect(reason)})}
          end
      end
    else
      {:error, %{kind: kind, message: message, details: details}} ->
        {:error, err(kind, message, details)}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Resolve the model id (open knob). Precedence:

    1. `config :pixir, :model` (programmatic override)
    2. `PIXIR_MODEL` env var
    3. `~/.pixir/config.json` → `"model"`
    4. the built-in default (`#{@default_model}`)
  """
  def default_model do
    Application.get_env(:pixir, :model) || System.get_env("PIXIR_MODEL") || config_model() ||
      @default_model
  end

  defp config_model, do: Config.file_model()

  @doc """
  The model catalog Pixir advertises to a client (epic A.5). A list of
  `%{"id" => slug, "name" => label, "default" => bool}` (string-keyed so it
  rides ACP `_meta` verbatim). Source: the built-in list (`#{@default_model}` &
  family), extended/overridden by a `~/.pixir/config.json` `"models"` array of
  slugs if present. The active `default_model/0` is always included and flagged
  `default: true` (so the client's picker has a default even if config narrows
  the list).
  """
  @spec models() :: [%{required(String.t()) => String.t() | boolean()}]
  def models do
    default = default_model()

    config_models()
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

  def request_body_preview(request, opts) when is_map(request) do
    model = request[:model] || Keyword.get(opts, :model) || default_model()
    base_url = Keyword.get(opts, :base_url, @default_base_url)

    reasoning_effort =
      normalize_reasoning_effort(
        request[:reasoning_effort] || opts[:reasoning_effort] || Config.reasoning_effort()
      )

    text_verbosity =
      normalize_text_verbosity(
        request[:text_verbosity] || opts[:text_verbosity] || Config.text_verbosity()
      )

    build_body(model, request, reasoning_effort, text_verbosity, base_url)
  end

  def request_body_preview(_request, _opts) do
    {:error,
     %{
       kind: :invalid_args,
       message: "request_body_preview/2 requires a Provider request map.",
       details: %{"expected" => "map"}
     }}
  end

  # A `"models"` array of slug strings from `~/.pixir/config.json`, or nil when
  # absent/malformed (falls back to the built-in list). Non-string entries are
  # dropped; an empty/invalid array yields nil so the built-in list stands.
  defp config_models, do: Config.file_models()

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

    case stream(request, Keyword.put(opts, :on_delta, fn _ -> :ok end)) do
      {:ok, _result} -> {:ok, %{model: opts[:model] || default_model()}}
      {:error, _} = error -> error
    end
  end

  @doc "Map a tool definition from a `__tool__/0` callback to a Responses function tool."
  @spec tool_spec(map()) :: map()
  def tool_spec(%{name: name, description: desc, parameters: params}) do
    %{"type" => "function", "name" => name, "description" => desc, "parameters" => params}
  end

  # ── request building ──────────────────────────────────────────────────────

  defp build_body(model, request, reasoning_effort, text_verbosity, base_url) do
    with {:ok, hosted_tools} <- HostedTools.from_request(request),
         {:ok, hosted_include} <- HostedTools.include_fields(request, hosted_tools) do
      tools = combine_tools(request[:tools], hosted_tools)

      include = ["reasoning.encrypted_content"] ++ hosted_include

      body = %{
        "model" => model,
        "store" => false,
        "stream" => true,
        "instructions" => request[:system_prompt] || "You are a helpful coding assistant.",
        "input" =>
          openai_input_items(
            developer_context_items(request[:developer_context]) ++
              fold_input(request[:history] || [], model,
                workspace: request[:workspace] || File.cwd!()
              )
          ),
        "include" => Enum.uniq(include),
        "tool_choice" => "auto",
        "parallel_tool_calls" => true
      }

      {:ok,
       body
       |> maybe_put_reasoning(reasoning_effort)
       |> maybe_put_text(request[:output_schema], text_verbosity)
       |> maybe_put_tools(tools)
       |> maybe_put_prompt_cache_key(request[:prompt_cache_key])
       |> maybe_put_prompt_cache_retention(request[:prompt_cache_retention], base_url)}
    end
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

  defp combine_tools(tools, hosted_tools) do
    local_tools = if is_list(tools), do: tools, else: []
    hosted_tools = if is_list(hosted_tools), do: hosted_tools, else: []
    local_tools ++ hosted_tools
  end

  defp maybe_put_prompt_cache_key(body, key) when is_binary(key) and key != "",
    do: Map.put(body, "prompt_cache_key", key)

  defp maybe_put_prompt_cache_key(body, _), do: body

  defp maybe_put_prompt_cache_retention(body, retention, base_url)
       when retention in ["24h", "in_memory"] do
    if chatgpt_codex_backend?(base_url) do
      body
    else
      Map.put(body, "prompt_cache_retention", retention)
    end
  end

  defp maybe_put_prompt_cache_retention(body, _retention, _base_url), do: body

  defp chatgpt_codex_backend?(base_url) do
    base_url
    |> to_string()
    |> String.contains?("chatgpt.com/backend-api")
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
    |> Enum.reduce(%{items: [], pending_calls: %{}}, fn {event, index}, state ->
      fold_event(event, state, model, workspace,
        current_user?: latest_user_index == index,
        active_turn?: is_integer(latest_user_index) and index >= latest_user_index
      )
    end)
    |> close_orphan_tool_calls()
    |> Map.fetch!(:items)
  end

  defp fold_event(
         %{type: :tool_call, data: %{"call_id" => id}} = event,
         state,
         model,
         workspace,
         _opts
       ) do
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
      items =
        to_input_item(event, model,
          workspace: workspace,
          resource_view_rehydrate?: Keyword.get(opts, :active_turn?, false)
        )

      state
      |> Map.update!(:items, &(&1 ++ items))
      |> Map.update!(:pending_calls, &Map.delete(&1, id))
    else
      state
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
    state = close_orphan_tool_calls(state)

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

  defp transparent_while_tool_pending?(%{type: type})
       when type in [:permission_decision, :provider_usage, :subagent_event, :workflow_event],
       do: true

  defp transparent_while_tool_pending?(_event), do: false

  defp close_orphan_tool_calls(%{pending_calls: pending} = state) when map_size(pending) == 0,
    do: state

  defp close_orphan_tool_calls(%{items: items, pending_calls: pending} = state) do
    fallbacks =
      pending
      |> Enum.sort_by(fn {call_id, _event} -> call_id end)
      |> Enum.map(fn {call_id, event} ->
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
      end)

    %{state | items: items ++ fallbacks, pending_calls: %{}}
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
        (data["summary"] || "")

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

  defp base_headers do
    [
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"openai-beta", "responses=experimental"},
      {"originator", "pixir"}
    ]
  end

  defp resolve_url(base_url) do
    normalized = String.trim_trailing(base_url, "/")

    cond do
      String.ends_with?(normalized, "/codex/responses") -> normalized
      String.ends_with?(normalized, "/codex") -> normalized <> "/responses"
      true -> normalized <> "/codex/responses"
    end
  end

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

  defp structured_error?(%{error: %{kind: _}}), do: true
  defp structured_error?(_), do: false

  # ── streaming reducer ─────────────────────────────────────────────────────

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}
  defp handle_chunk({:headers, _headers}, acc), do: acc

  defp handle_chunk({:metadata, metadata}, acc) when is_map(metadata),
    do: %{acc | provider_metadata: Map.merge(acc.provider_metadata, metadata)}

  defp handle_chunk({:data, data}, %{status: status} = acc) when status in 200..299,
    do: feed_sse(acc, data)

  defp handle_chunk({:data, data}, acc), do: %{acc | err_body: acc.err_body <> data}

  defp feed_sse(acc, data) do
    buffer = acc.buffer <> data
    blocks = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(blocks, -1)
    Enum.reduce(complete, %{acc | buffer: rest}, &apply_sse_block/2)
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
    call = %{
      call_id: item["call_id"],
      name: item["name"],
      args: decode_args(item["arguments"])
    }

    %{acc | output_items: [{:function_call, call} | acc.output_items]}
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

  defp apply_event(
         {:ok, %{"type" => "response.completed", "response" => %{"usage" => usage}}},
         acc
       )
       when is_map(usage) do
    %{acc | usage: usage, usage_summary: usage_summary(usage)}
  end

  defp apply_event({:ok, %{"type" => "response.completed", "usage" => usage}}, acc)
       when is_map(usage) do
    %{acc | usage: usage, usage_summary: usage_summary(usage)}
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

    # ADR 0020: in-band stream errors (e.g. `response.failed` over a 200 SSE
    # stream or the WebSocket transport) carry overflow rejections too. Unlike
    # HTTP classification, this path has no status guard, so message-only matches
    # are accepted only for provider/context-shaped error families.
    kind =
      if stream_context_overflow?(error["type"] || "", error["code"] || "", error["message"]) do
        :context_overflow
      else
        :provider_http_error
      end

    %{
      acc
      | stream_error:
          err(kind, message, %{
            status: status,
            event_type: event_type,
            code: error["code"],
            type: error["type"],
            param: error["param"]
          })
    }
  end

  defp put_stream_error(acc, _event_type, _error), do: acc

  defp decode_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

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
       finish_reason: if(calls == [], do: :stop, else: :tool_calls)
     }}
  end

  defp finalize(acc), do: {:error, classify_http_error(acc.status, acc.err_body)}

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
  defp classify_http_error(status, body) do
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
