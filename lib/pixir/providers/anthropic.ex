defmodule Pixir.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API transport core for Pixir's Provider seam.

  This module accepts Anthropic-native request maps and returns the same assembled
  streamed shape the Turn loop consumes from providers. The OpenAI Responses
  implementation stays separate in `Pixir.Provider`; this namespace owns Anthropic
  request shaping, SSE event decoding, usage normalization, and transport selection.
  """

  alias Pixir.Provider.{FinchTransport, OutputTruncation, StreamIdle, ToolCall, TransportError}
  alias Pixir.Providers.ErrBody
  alias Pixir.Providers.Anthropic.Replay
  alias Pixir.Providers.Anthropic.Prompt
  alias Pixir.Providers.Anthropic.Tools, as: AnthropicTools
  alias Pixir.Tool

  @default_endpoint "https://api.anthropic.com/v1/messages"
  @default_max_tokens 32_000
  @anthropic_version "2023-06-01"
  @valid_reasoning_efforts ~w(low medium high xhigh)

  @type request :: %{
          optional(:model) => String.t(),
          optional(:messages) => [map()],
          optional(:history) => [map()],
          optional(:system) => String.t() | [map()],
          optional(:system_prompt) => String.t(),
          optional(:tools) => [map()],
          optional(:max_tokens) => pos_integer(),
          optional(:reasoning_effort) => String.t() | atom()
        }

  @type result :: %{
          text: String.t(),
          reasoning: String.t(),
          reasoning_items: [map()],
          function_calls: [%{call_id: String.t(), name: String.t(), args: map()}],
          output_items: [{:reasoning, map()} | {:function_call, map()}],
          usage: map() | nil,
          usage_summary: map(),
          provider_metadata: map(),
          finish_reason: :stop | :tool_calls,
          output_truncation: OutputTruncation.t()
        }

  @doc "Stream one Anthropic Messages API call over HTTP/SSE."
  @spec stream(request(), keyword()) :: {:ok, result()} | {:error, map()}
  def stream(request, opts \\ [])

  def stream(request, opts) when is_map(request) and not is_struct(request) do
    max_retries = Keyword.get_lazy(opts, :max_retries, &Pixir.Config.max_retries/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    attempt(request, opts, 0, max_retries, sleep)
  end

  def stream(_request, _opts) do
    {:error,
     Tool.error(:invalid_args, "Anthropic.stream/2 requires a plain request map.", %{
       expected: "plain_map"
     })}
  end

  defp attempt(request, opts, n, max, sleep) do
    case do_stream(request, opts) do
      {:ok, result} ->
        {:ok, put_retry_metadata(result, n, max)}

      {:error, error} ->
        if n < max and retryable?(error) do
          sleep.(retry_delay_ms(error, n))
          attempt(request, opts, n + 1, max, sleep)
        else
          {:error, error}
        end
    end
  end

  defp put_retry_metadata(result, n, max) do
    metadata =
      result
      |> Map.get(:provider_metadata, %{})
      |> Map.put("retry_count", n)
      |> Map.put("max_retries", max)

    Map.put(result, :provider_metadata, metadata)
  end

  defp retry_delay_ms(%{error: %{details: details}}, n) when is_map(details) do
    case Map.get(details, :retry_after_ms) || Map.get(details, "retry_after_ms") do
      nil -> backoff_ms(n)
      retry_after_ms -> min(retry_after_ms, 30_000)
    end
  end

  defp retry_delay_ms(_error, n), do: backoff_ms(n)

  defp backoff_ms(n), do: min(8_000, 500 * Integer.pow(2, n))

  defp retryable?(%{error: %{kind: kind}}) when kind in [:network, :rate_limited], do: true

  defp retryable?(%{error: %{kind: :provider_http_error, details: details}})
       when is_map(details) do
    cond do
      Map.get(details, :retryable) == false or Map.get(details, "retryable") == false ->
        false

      true ->
        retryable_detail?(details) ||
          retryable_status?(Map.get(details, :status) || Map.get(details, "status"))
    end
  end

  defp retryable?(_error), do: false

  defp retryable_detail?(details),
    do: Map.get(details, :retryable) || Map.get(details, "retryable") || false

  defp retryable_status?(status), do: status in [500, 502, 503, 504, 529]

  defp do_stream(request, opts) do
    with :ok <- validate_request_inputs(request),
         {:ok, transport_metadata} <-
           transport_metadata(Keyword.get(opts, :provider_transport, :auto)),
         {:ok, body, prompt_metadata} <- safe_build_body(request, opts),
         {:ok, encoded_body} <- encode_body(body),
         {:ok, headers} <- auth_headers(opts) do
      http_request = %{
        method: :post,
        url: resolve_url(Keyword.get(opts, :base_url)),
        headers: base_headers() ++ headers,
        body: encoded_body
      }

      init = initial_acc(opts, request, transport_metadata, prompt_metadata)

      case run_stream(http_request, init, opts) do
        {:ok, acc} ->
          complete_stream(acc)

        {:error, reason, _acc} ->
          {:error, TransportError.project(reason)}

        {:error, reason} ->
          {:error, TransportError.project(reason)}
      end
    else
      {:error, %{ok: false} = error} ->
        {:error, error}

      {:error, %{kind: kind, message: message, details: details}} ->
        {:error, Tool.error(kind, message, details)}

      {:error, reason} ->
        {:error,
         Tool.error(:network, "provider stream failed", %{
           reason: TransportError.reason(reason)
         })}
    end
  end

  defp initial_acc(opts, request, transport_metadata, prompt_metadata) do
    %{
      status: nil,
      headers: [],
      buffer: "",
      err_body: ErrBody.new(),
      text: "",
      reasoning: "",
      blocks: %{},
      output_items: [],
      usage: nil,
      model: get_field(request, :model) || Keyword.get(opts, :model),
      stop_reason: nil,
      stop_details: nil,
      stream_error: nil,
      delivered_output: false,
      on_delta: Keyword.get(opts, :on_delta, fn _ -> :ok end),
      provider_metadata: Map.merge(transport_metadata, prompt_metadata)
    }
  end

  defp run_stream(http_request, init, opts) do
    transport = Keyword.get(opts, :transport, FinchTransport)

    StreamIdle.run(
      fn activity ->
        reducer = fn chunk, acc ->
          activity.()
          handle_chunk(chunk, acc)
        end

        call_transport(transport, http_request, init, reducer)
      end,
      opts,
      "http_sse"
    )
  end

  defp call_transport(transport, http_request, acc, fun) when is_function(transport, 3),
    do: transport.(http_request, acc, fun)

  defp call_transport(transport, http_request, acc, fun) when is_atom(transport),
    do: transport.stream(http_request, acc, fun)

  defp transport_metadata(requested) do
    case normalize_transport(requested) do
      {:ok, active, preference} ->
        {:ok,
         %{
           "active_transport" => active,
           "transport_preference" => preference
         }}

      {:error, requested_value} ->
        {:error,
         Tool.error(
           :unsupported_transport,
           "Anthropic provider does not support the requested transport.",
           %{
             requested: requested_value,
             supported: ["auto", "http_sse"],
             next_actions: ["use provider_transport: :auto", "use provider_transport: :http_sse"]
           }
         )}
    end
  end

  defp normalize_transport(nil), do: {:ok, "http_sse", "auto"}
  defp normalize_transport(:auto), do: {:ok, "http_sse", "auto"}
  defp normalize_transport("auto"), do: {:ok, "http_sse", "auto"}
  defp normalize_transport(:http_sse), do: {:ok, "http_sse", "http_sse"}
  defp normalize_transport("http_sse"), do: {:ok, "http_sse", "http_sse"}
  defp normalize_transport(:websocket), do: {:error, :websocket}
  defp normalize_transport("websocket"), do: {:error, "websocket"}
  defp normalize_transport(other), do: {:error, other}

  defp validate_request_inputs(request) do
    with :ok <- reject_request_field_collisions(request),
         :ok <- validate_history_input(get_field(request, :history)),
         :ok <- validate_message_input(get_field(request, :messages)),
         :ok <- validate_tool_input(get_field(request, :tools)),
         :ok <- validate_system_input(get_field(request, :system)),
         :ok <- validate_optional_text(request, :system_prompt),
         :ok <- validate_optional_text(request, :developer_context),
         :ok <- validate_optional_text(request, :agent_instructions),
         :ok <- validate_optional_text(request, :skills_index),
         :ok <- validate_prompt_mode(request),
         :ok <- validate_previous_turn_boundary(request),
         :ok <- validate_reasoning_effort_input(request) do
      :ok
    end
  end

  defp reject_request_field_collisions(request) do
    fields = [
      :model,
      :messages,
      :history,
      :system,
      :system_prompt,
      :tools,
      :developer_context,
      :agent_instructions,
      :skills_index,
      :prompt_mode,
      :previous_turn_boundary_seq,
      :max_tokens,
      :reasoning_effort,
      :web_search,
      :hosted_tools,
      :output_schema
    ]

    case Enum.find(fields, &request_field_collision?(request, &1)) do
      nil -> :ok
      field -> invalid_request_field(field, "normalized_key_collision")
    end
  end

  defp request_field_collision?(request, field),
    do: Map.has_key?(request, field) and Map.has_key?(request, Atom.to_string(field))

  defp validate_history_input(nil), do: :ok

  defp validate_history_input(history) when is_list(history) do
    if proper_list?(history) and Enum.all?(history, &valid_history_event?/1),
      do: :ok,
      else: invalid_request_field(:history, "invalid_event_list")
  end

  defp validate_history_input(_history),
    do: invalid_request_field(:history, "invalid_event_list")

  defp valid_history_event?(event) when is_map(event) and not is_struct(event) do
    event_type(event) in Pixir.Event.canonical_types() and
      not history_envelope_collision?(event) and json_safe_anthropic_term?(event)
  end

  defp valid_history_event?(_event), do: false

  defp history_envelope_collision?(event) do
    Enum.any?([:type, :data, :seq, :session_id, :id, :ts], fn field ->
      request_field_collision?(event, field)
    end)
  end

  defp validate_message_input(nil), do: :ok

  defp validate_message_input(messages) when is_list(messages) do
    if proper_list?(messages) and Enum.all?(messages, &plain_json_safe_map?/1),
      do: :ok,
      else: invalid_request_field(:messages, "invalid_message_list")
  end

  defp validate_message_input(_messages),
    do: invalid_request_field(:messages, "invalid_message_list")

  defp validate_tool_input(nil), do: :ok

  defp validate_tool_input(tools) when is_list(tools) do
    if proper_list?(tools) and Enum.all?(tools, &plain_json_safe_map?/1),
      do: :ok,
      else: invalid_request_field(:tools, "invalid_tool_list")
  end

  defp validate_tool_input(_tools),
    do: invalid_request_field(:tools, "invalid_tool_list")

  defp validate_system_input(nil), do: :ok

  defp validate_system_input(system) when is_binary(system) do
    if String.valid?(system), do: :ok, else: invalid_request_field(:system, "invalid_utf8")
  end

  defp validate_system_input(system) when is_list(system) do
    if proper_list?(system) and Enum.all?(system, &plain_json_safe_map?/1),
      do: :ok,
      else: invalid_request_field(:system, "invalid_system_blocks")
  end

  defp validate_system_input(_system),
    do: invalid_request_field(:system, "invalid_type")

  defp validate_optional_text(request, field) do
    case get_field(request, field) do
      nil ->
        :ok

      value when is_binary(value) ->
        if String.valid?(value), do: :ok, else: invalid_request_field(field, "invalid_utf8")

      _value ->
        invalid_request_field(field, "invalid_type")
    end
  end

  defp validate_prompt_mode(request) do
    case get_field(request, :prompt_mode) do
      nil -> :ok
      mode when mode in [:build, :plan] -> :ok
      _mode -> invalid_request_field(:prompt_mode, "unsupported_mode")
    end
  end

  defp validate_previous_turn_boundary(request) do
    case get_field(request, :previous_turn_boundary_seq) do
      nil -> :ok
      value when is_integer(value) and value >= 0 -> :ok
      _value -> invalid_request_field(:previous_turn_boundary_seq, "invalid_boundary")
    end
  end

  defp validate_reasoning_effort_input(request) do
    case get_field(request, :reasoning_effort) do
      nil ->
        :ok

      value when is_atom(value) ->
        :ok

      value when is_binary(value) ->
        if String.valid?(value),
          do: :ok,
          else: invalid_request_field(:reasoning_effort, "invalid_utf8")

      _value ->
        invalid_request_field(:reasoning_effort, "invalid_type")
    end
  end

  defp plain_json_safe_map?(value),
    do: is_map(value) and not is_struct(value) and json_safe_anthropic_term?(value)

  defp json_safe_anthropic_term?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value),
       do: true

  defp json_safe_anthropic_term?(value) when is_binary(value), do: String.valid?(value)

  defp json_safe_anthropic_term?(value) when is_list(value) do
    proper_list?(value) and Enum.all?(value, &json_safe_anthropic_term?/1)
  end

  defp json_safe_anthropic_term?(value) when is_struct(value), do: false

  defp json_safe_anthropic_term?(value) when is_map(value) do
    with {:ok, keys} <- normalized_json_keys(Map.keys(value)),
         true <- length(keys) == MapSet.size(MapSet.new(keys)) do
      Enum.all?(value, fn {_key, nested} -> json_safe_anthropic_term?(nested) end)
    else
      _ -> false
    end
  end

  defp json_safe_anthropic_term?(_value), do: false

  defp normalized_json_keys(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn
      key, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, [Atom.to_string(key) | acc]}}

      key, {:ok, acc} when is_binary(key) ->
        if String.valid?(key),
          do: {:cont, {:ok, [key | acc]}},
          else: {:halt, :error}

      _key, _acc ->
        {:halt, :error}
    end)
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp invalid_request_field(field, reason) do
    {:error,
     Tool.error(:invalid_args, "Anthropic request body fields must be JSON-safe.", %{
       field: field,
       reason: reason
     })}
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

  defp safe_build_body(request, opts) do
    build_body(request, opts)
  rescue
    _exception -> invalid_request_field(:body, "body_build_failed")
  catch
    _kind, _reason -> invalid_request_field(:body, "body_build_failed")
  end

  defp build_body(request, opts) do
    with :ok <- reject_output_schema(request),
         :ok <- reject_hosted_tools(request),
         {:ok, model} <- request_model(request, opts),
         {:ok, prompt_parts} <- request_prompt_parts(request, model),
         {:ok, tools} <- AnthropicTools.project(get_field(request, :tools)),
         {:ok, max_tokens} <- max_tokens(request, opts),
         {:ok, effort} <-
           normalize_reasoning_effort(
             get_field(request, :reasoning_effort) || Keyword.get(opts, :reasoning_effort)
           ) do
      body = %{
        "model" => model,
        "messages" => prompt_parts.messages,
        "max_tokens" => max_tokens,
        "stream" => true
      }

      {:ok,
       body
       |> maybe_put("system", prompt_parts.system)
       |> maybe_put("tools", tools)
       |> maybe_put_effort(effort), prompt_parts.provider_metadata}
    end
  end

  defp request_prompt_parts(request, model) do
    if prompt_mode_present?(request) do
      with {:ok, messages, prev_turn_boundary} <- request_messages_with_boundary(request, model),
           {:ok, prompt} <-
             Prompt.build(%{
               mode: get_field(request, :prompt_mode),
               skills_index: get_field(request, :skills_index),
               messages: messages,
               late_context: pa1_late_context(request),
               prev_turn_boundary: prev_turn_boundary
             }) do
        {:ok,
         %{
           messages: prompt.messages,
           system: prompt.system,
           provider_metadata: %{"prompt_contract" => prompt.contract}
         }}
      end
    else
      with {:ok, messages} <- request_messages(request, model),
           {:ok, system} <-
             optional_system(get_field(request, :system) || get_field(request, :system_prompt)) do
        {:ok, %{messages: messages, system: system, provider_metadata: %{}}}
      end
    end
  end

  defp prompt_mode_present?(request),
    do: Map.has_key?(request, :prompt_mode) or Map.has_key?(request, "prompt_mode")

  defp request_messages_with_boundary(request, model) do
    cond do
      is_list(get_field(request, :history)) ->
        history = request_provider_history(get_field(request, :history))
        messages = fold_history(history, model)

        prev_turn_boundary =
          previous_turn_content_count(
            history,
            get_field(request, :previous_turn_boundary_seq),
            model
          )

        {:ok, messages, prev_turn_boundary}

      is_list(get_field(request, :messages)) ->
        {:ok, get_field(request, :messages), nil}

      true ->
        {:error,
         Tool.error(:invalid_args, "Anthropic request is missing a required field.", %{
           field: :messages,
           expected: "list"
         })}
    end
  end

  defp previous_turn_content_count(_history, nil, _model), do: nil

  defp previous_turn_content_count(history, previous_turn_boundary_seq, model)
       when is_integer(previous_turn_boundary_seq) and previous_turn_boundary_seq >= 0 do
    case leading_compaction_event(history) do
      head when is_map(head) ->
        if is_integer(event_seq(head)) and event_seq(head) > previous_turn_boundary_seq do
          # HONEST CLAMP: a compaction fired during the current turn, so there is no
          # stable prior-turn prefix this turn; the cache re-primes after compaction anyway.
          nil
        else
          previous_turn_prefix_content_count(history, previous_turn_boundary_seq, model)
        end

      _other ->
        previous_turn_prefix_content_count(history, previous_turn_boundary_seq, model)
    end
  end

  defp previous_turn_content_count(_history, _previous_turn_boundary_seq, _model), do: nil

  defp previous_turn_prefix_content_count(history, previous_turn_boundary_seq, model) do
    history
    |> Enum.take_while(fn event ->
      seq = event_seq(event)
      is_integer(seq) and seq <= previous_turn_boundary_seq
    end)
    |> fold_history(model)
    |> content_block_count()
  end

  defp leading_compaction_event([head | _tail]) do
    if event_type(head) == :history_compaction, do: head, else: nil
  end

  defp leading_compaction_event(_history), do: nil

  defp event_seq(%{seq: seq}) when is_integer(seq), do: seq
  defp event_seq(%{"seq" => seq}) when is_integer(seq), do: seq

  defp event_seq(%{seq: seq}) when is_binary(seq) do
    case Integer.parse(seq) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp event_seq(%{"seq" => seq}) when is_binary(seq) do
    case Integer.parse(seq) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp event_seq(_event), do: nil

  defp content_block_count(messages) do
    Enum.reduce(messages, 0, fn message, count ->
      count + length(Map.get(message, "content", []))
    end)
  end

  defp pa1_late_context(request) do
    [
      non_empty_string(get_field(request, :developer_context)),
      agent_instructions_section(request)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp agent_instructions_section(request) do
    case non_empty_string(get_field(request, :agent_instructions)) do
      nil -> nil
      text -> "Subagent role instructions:\n" <> text
    end
  end

  defp non_empty_string(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp non_empty_string(_value), do: nil

  defp request_model(request, opts) do
    case get_field(request, :model) || Keyword.get(opts, :model) do
      value when is_binary(value) ->
        if String.valid?(value) and String.trim(value) != "" do
          {:ok, value}
        else
          invalid_request_field(:model, "invalid_model")
        end

      _ ->
        invalid_request_field(:model, "invalid_model")
    end
  end

  defp request_messages(request, model) do
    cond do
      is_list(get_field(request, :messages)) ->
        {:ok, get_field(request, :messages)}

      is_list(get_field(request, :history)) ->
        {:ok, request |> get_field(:history) |> request_provider_history() |> fold_history(model)}

      true ->
        {:error,
         Tool.error(:invalid_args, "Anthropic request is missing a required field.", %{
           field: :messages,
           expected: "list"
         })}
    end
  end

  defp request_provider_history(history) do
    history
    |> Enum.map(&provider_history_event/1)
    |> Pixir.Compaction.provider_history()
  end

  defp provider_history_event(%{} = event) do
    # Compaction.provider_history/1 reads :type/:seq/:data as atom keys; raw
    # NDJSON events are string-keyed, so mirror all three (cold-resume rule).
    event
    |> Map.put_new(:type, event_type(event))
    |> Map.put_new(:seq, event_seq(event))
    |> Map.put_new(:data, event_data(event))
  end

  defp provider_history_event(event), do: event

  # One assistant turn's pending items accumulate as raw events (reasoning and
  # tool_call, arrival order) and render at flush through Replay.assistant_content:
  # thinking blocks re-inject verbatim, model- and dialect-guarded (ADR 0037 D5),
  # positioned exactly as captured next to their tool_use blocks.
  defp fold_history(history, model) do
    history
    |> Enum.reduce(
      %{
        messages: [],
        assistant_items: [],
        results: [],
        pending_calls: %{},
        deferred_skill_activations: %{}
      },
      &fold_history_event(&1, &2, model)
    )
    |> close_deferred_skill_activations(model)
    |> then(fn state ->
      flush_pending(state.messages, state.assistant_items, state.results, model)
    end)
  end

  defp fold_history_event(event, state, model) do
    case event_type(event) do
      :user_message ->
        append_history_text(state, "user", event_text(event), model)

      :assistant_message ->
        if get_field(event_data(event), :metadata) |> partial_metadata?() do
          state
        else
          append_history_text(state, "assistant", event_text(event), model)
        end

      :skill_activation ->
        case pending_skill_view_call_id(event, state.pending_calls) do
          {:ok, call_id} ->
            Map.update!(state, :deferred_skill_activations, fn deferred ->
              Map.update(deferred, call_id, [event], &(&1 ++ [event]))
            end)

          :error ->
            state
            |> close_deferred_skill_activations(model)
            |> close_pending_tool_calls_as_orphans(model)
            |> append_history_text(
              "user",
              Pixir.Skills.render_activation(event_data(event)),
              model
            )
        end

      :subagent_event ->
        case subagent_event_text(event_data(event)) do
          nil -> state
          text -> append_history_text(state, "user", text, model)
        end

      :history_compaction ->
        append_history_text(
          state,
          "user",
          Pixir.Compaction.render_for_provider(event_data(event)),
          model
        )

      :branch_summary ->
        append_history_text(
          state,
          "user",
          Pixir.BranchSummary.render_for_provider(event_data(event)),
          model
        )

      :tool_call ->
        state = close_deferred_skill_activations(state, model)
        call_id = get_field(event_data(event), :call_id)

        %{
          state
          | messages: flush_results(state.messages, state.results),
            assistant_items: state.assistant_items ++ [normalize_event(event, :tool_call)],
            results: [],
            pending_calls: Map.put(state.pending_calls, call_id, event)
        }

      :reasoning ->
        state = close_deferred_skill_activations(state, model)

        %{
          state
          | messages: flush_results(state.messages, state.results),
            assistant_items: state.assistant_items ++ [normalize_event(event, :reasoning)],
            results: []
        }

      :tool_result ->
        fold_history_tool_result(event, state, model)

      type when type in [:provider_usage, :turn_failed, :permission_decision] ->
        state

      _other ->
        state
    end
  end

  defp fold_history_tool_result(event, state, model) do
    call_id = get_field(event_data(event), :call_id)

    if Map.has_key?(state.deferred_skill_activations, call_id) do
      messages = flush_assistant_items(state.messages, state.assistant_items, model)
      messages = flush_results(messages, state.results ++ [tool_result_block(event)])

      messages =
        append_activation_messages(
          messages,
          Map.fetch!(state.deferred_skill_activations, call_id)
        )

      %{
        state
        | messages: messages,
          assistant_items: [],
          results: [],
          pending_calls: Map.delete(state.pending_calls, call_id),
          deferred_skill_activations: Map.delete(state.deferred_skill_activations, call_id)
      }
    else
      queue_tool_result(state, event, model)
    end
  end

  defp queue_tool_result(state, event, model) do
    call_id = get_field(event_data(event), :call_id)

    %{
      state
      | messages: flush_assistant_items(state.messages, state.assistant_items, model),
        assistant_items: [],
        results: state.results ++ [tool_result_block(event)],
        pending_calls: Map.delete(state.pending_calls, call_id)
    }
  end

  defp append_history_text(state, role, text, model) do
    state = close_deferred_skill_activations(state, model)

    %{
      state
      | messages:
          flush_pending(state.messages, state.assistant_items, state.results, model) ++
            [text_message(role, text)],
        assistant_items: [],
        results: [],
        pending_calls: %{},
        deferred_skill_activations: %{}
    }
  end

  defp close_deferred_skill_activations(
         %{deferred_skill_activations: deferred} = state,
         _model
       )
       when map_size(deferred) == 0,
       do: state

  defp close_deferred_skill_activations(state, model) do
    messages = flush_assistant_items(state.messages, state.assistant_items, model)
    messages = flush_results(messages, state.results)

    {messages, pending_calls} =
      state.deferred_skill_activations
      |> Enum.sort_by(fn {call_id, _events} -> call_id end)
      |> Enum.reduce({messages, state.pending_calls}, fn {call_id, activations},
                                                         {messages, pending_calls} ->
        call = Map.get(pending_calls, call_id)
        messages = flush_results(messages, [orphan_tool_result_block(call_id, call)])
        messages = append_activation_messages(messages, activations)
        {messages, Map.delete(pending_calls, call_id)}
      end)

    %{
      state
      | messages: messages,
        assistant_items: [],
        results: [],
        pending_calls: pending_calls,
        deferred_skill_activations: %{}
    }
  end

  defp close_pending_tool_calls_as_orphans(%{pending_calls: pending_calls} = state, _model)
       when map_size(pending_calls) == 0,
       do: state

  defp close_pending_tool_calls_as_orphans(state, model) do
    messages = flush_assistant_items(state.messages, state.assistant_items, model)
    messages = flush_results(messages, state.results)

    orphan_results =
      state.pending_calls
      |> Enum.sort_by(fn {call_id, _call} -> call_id end)
      |> Enum.map(fn {call_id, call} -> orphan_tool_result_block(call_id, call) end)

    %{
      state
      | messages: flush_results(messages, orphan_results),
        assistant_items: [],
        results: [],
        pending_calls: %{}
    }
  end

  defp orphan_tool_result_block(call_id, call) do
    tool = call |> event_data() |> get_field(:name)

    %{
      "type" => "tool_result",
      "tool_use_id" => call_id,
      "content" =>
        Jason.encode!(%{
          ok: false,
          error: %{
            kind: "orphan_tool_call",
            message: "Pixir replay found a tool_call without a matching tool_result",
            details: %{call_id: call_id, tool: tool}
          }
        }),
      "is_error" => true
    }
  end

  defp append_activation_messages(messages, activations) do
    messages ++
      Enum.map(activations, fn activation ->
        text_message("user", Pixir.Skills.render_activation(event_data(activation)))
      end)
  end

  defp pending_skill_view_call_id(event, pending_calls) do
    activation_name = get_field(event_data(event), :name)

    matching_call_ids =
      if is_binary(activation_name) do
        Enum.reduce(pending_calls, [], fn {call_id, call}, matches ->
          call_data = event_data(call)
          args = get_field(call_data, :args)
          path = if is_map(args), do: get_field(args, :path) || "SKILL.md", else: nil

          if get_field(call_data, :name) == "skill_view" and is_map(args) and
               get_field(args, :name) == activation_name and is_binary(path) and
               Pixir.Skills.main_file?(path) do
            [call_id | matches]
          else
            matches
          end
        end)
      else
        []
      end

    case matching_call_ids do
      [call_id] -> {:ok, call_id}
      _zero_or_ambiguous -> :error
    end
  end

  defp flush_pending(messages, assistant_items, results, model) do
    messages
    |> flush_assistant_items(assistant_items, model)
    |> flush_results(results)
  end

  # Replay expects atom-keyed envelopes (`%{type: ..., data: ...}`); raw decoded
  # history lines arrive string-keyed, so pending items normalize here once.
  defp normalize_event(event, type), do: %{type: type, data: event_data(event)}

  defp flush_assistant_items(messages, [], _model), do: messages

  defp flush_assistant_items(messages, assistant_items, model) do
    case Replay.assistant_content(assistant_items, model, &tool_use_block/1) do
      [] -> messages
      content -> messages ++ [%{"role" => "assistant", "content" => content}]
    end
  end

  defp flush_results(messages, []), do: messages

  defp flush_results(messages, results),
    do: messages ++ [%{"role" => "user", "content" => results}]

  defp text_message(role, text),
    do: %{"role" => role, "content" => [%{"type" => "text", "text" => text || ""}]}

  defp tool_use_block(event) do
    data = event_data(event)

    %{
      "type" => "tool_use",
      "id" => get_field(data, :call_id),
      "name" => get_field(data, :name),
      "input" => get_field(data, :args) || %{}
    }
  end

  defp tool_result_block(event) do
    data = event_data(event)

    block = %{
      "type" => "tool_result",
      "tool_use_id" => get_field(data, :call_id),
      "content" => tool_result_content(data)
    }

    if tool_result_error?(data), do: Map.put(block, "is_error", true), else: block
  end

  defp tool_result_error?(data),
    do: get_field(data, :ok) == false or is_map(get_field(data, :error))

  # Content mirrors the OpenAI fold's tool_output_text exactly so a tool result
  # reads the same on both providers; is_error is the Anthropic-only addition.
  defp tool_result_content(data) do
    case get_field(data, :output) do
      output when is_binary(output) -> output
      _ -> data |> Map.drop(["call_id"]) |> Jason.encode!()
    end
  end

  defp subagent_event_text(data) do
    if get_field(data, :event) in ["finished", "failed", "cancelled", "timed_out"] do
      "Subagent #{get_field(data, :subagent_id)} (#{get_field(data, :agent)}) " <>
        "#{get_field(data, :status)}: " <>
        (get_field(data, :summary) || "") <>
        Pixir.Provider.OutputTruncationSummary.child_context_suffix(data)
    end
  end

  defp event_type(%{type: type}) when is_atom(type), do: type
  defp event_type(%{type: type}) when is_binary(type), do: safe_event_type(type)
  defp event_type(%{"type" => type}) when is_binary(type), do: safe_event_type(type)
  defp event_type(_event), do: nil

  # Never String.to_existing_atom on decoded event types (the documented cold
  # resume rule): unknown types fold to nil and are skipped, not crashed on.
  defp safe_event_type(type) do
    Enum.find(Pixir.Event.canonical_types(), &(Atom.to_string(&1) == type))
  end

  defp event_data(%{data: data}) when is_map(data), do: data
  defp event_data(%{"data" => data}) when is_map(data), do: data
  defp event_data(_event), do: %{}

  defp event_text(event), do: get_field(event_data(event), :text) || ""

  defp reject_output_schema(request) do
    if Map.has_key?(request, :output_schema) or Map.has_key?(request, "output_schema") do
      {:error,
       Tool.error(:invalid_args, "Anthropic structured output mapping lands in a later phase.", %{
         field: :output_schema,
         next_action: "omit output_schema for Anthropic requests in this phase"
       })}
    else
      :ok
    end
  end

  defp reject_hosted_tools(request) do
    cond do
      hosted_web_search_requested?(get_field(request, :web_search)) ->
        {:error,
         Tool.error(:invalid_args, "Anthropic provider does not support hosted web_search.", %{
           field: :web_search,
           unsupported_capability: "provider_hosted_web_search",
           next_action: "omit web_search or use an OpenAI Responses provider"
         })}

      hosted_tools_requested?(get_field(request, :hosted_tools)) ->
        {:error,
         Tool.error(
           :invalid_args,
           "Anthropic provider does not support Provider-hosted tools.",
           %{
             field: :hosted_tools,
             unsupported_capability: "provider_hosted_tools",
             next_action: "omit hosted_tools or use an OpenAI Responses provider"
           }
         )}

      true ->
        :ok
    end
  end

  defp hosted_web_search_requested?(nil), do: false
  defp hosted_web_search_requested?(false), do: false
  defp hosted_web_search_requested?(%{"enabled" => false}), do: false
  defp hosted_web_search_requested?(%{enabled: false}), do: false
  defp hosted_web_search_requested?(_value), do: true

  defp hosted_tools_requested?(nil), do: false
  defp hosted_tools_requested?([]), do: false
  defp hosted_tools_requested?(_tools), do: true

  defp optional_system(nil), do: {:ok, nil}
  defp optional_system(system) when is_binary(system), do: {:ok, system}
  defp optional_system(system) when is_list(system), do: {:ok, system}

  defp optional_system(_system) do
    {:error,
     Tool.error(:invalid_args, "Anthropic system must be a string or a list of text blocks.", %{
       field: :system
     })}
  end

  defp max_tokens(request, opts) do
    value = get_field(request, :max_tokens) || Keyword.get(opts, :max_tokens, @default_max_tokens)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error,
       Tool.error(:invalid_args, "Anthropic max_tokens must be a positive integer.", %{
         field: :max_tokens
       })}
    end
  end

  defp normalize_reasoning_effort(nil), do: {:ok, nil}

  defp normalize_reasoning_effort(effort) when is_atom(effort),
    do: effort |> Atom.to_string() |> normalize_reasoning_effort()

  defp normalize_reasoning_effort(effort) when is_binary(effort) do
    if effort in @valid_reasoning_efforts do
      {:ok, effort}
    else
      {:error,
       Tool.error(:invalid_args, "Anthropic reasoning_effort is not supported.", %{
         field: :reasoning_effort,
         supported: @valid_reasoning_efforts,
         reason: "unsupported_value"
       })}
    end
  end

  defp normalize_reasoning_effort(_effort) do
    {:error,
     Tool.error(:invalid_args, "Anthropic reasoning_effort is not supported.", %{
       field: :reasoning_effort,
       supported: @valid_reasoning_efforts,
       reason: "invalid_type"
     })}
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_effort(body, nil), do: body

  defp maybe_put_effort(body, effort),
    do: Map.put(body, "output_config", %{"effort" => effort})

  defp maybe_put_cache_ttl(cache, usage, ttl_key) do
    case cache_creation_ttl_tokens(usage, ttl_key) do
      value when is_integer(value) -> Map.put(cache, ttl_key, value)
      _ -> cache
    end
  end

  defp cache_creation_ttl_tokens(usage, ttl_key) when is_map(usage) do
    case get_in(usage, ["cache_creation", ttl_key]) || get_in(usage, [:cache_creation, ttl_key]) ||
           get_in(usage, [:cache_creation, String.to_atom(ttl_key)]) do
      value when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp cache_creation_ttl_tokens(_usage, _ttl_key), do: nil

  defp get_field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp auth_headers(opts) do
    api_key = opts[:api_key] || System.get_env("ANTHROPIC_API_KEY")

    if is_binary(api_key) and String.trim(api_key) != "" do
      {:ok, [{"x-api-key", api_key}]}
    else
      {:error,
       Tool.error(:not_authenticated, "Anthropic API key is required.", %{
         env: "ANTHROPIC_API_KEY",
         next_action:
           "Set ANTHROPIC_API_KEY or pass :api_key to Pixir.Providers.Anthropic.stream/2."
       })}
    end
  end

  defp base_headers do
    [
      {"content-type", "application/json"},
      {"anthropic-version", @anthropic_version}
    ]
  end

  defp resolve_url(nil), do: @default_endpoint

  defp resolve_url(base_url) do
    base = to_string(base_url) |> String.trim_trailing("/")

    if String.ends_with?(base, "/v1/messages") do
      base
    else
      base <> "/v1/messages"
    end
  end

  defp handle_chunk({:status, status}, acc), do: %{acc | status: status}

  defp handle_chunk({:headers, headers}, acc) when is_list(headers) do
    %{acc | headers: acc.headers ++ headers}
  end

  defp handle_chunk({:data, data}, %{status: status} = acc)
       when is_integer(status) and (status < 200 or status >= 300) do
    %{acc | err_body: ErrBody.append(acc.err_body, to_string(data))}
  end

  defp handle_chunk({:data, data}, acc), do: decode_sse(acc.buffer <> to_string(data), acc)
  defp handle_chunk(_chunk, acc), do: acc

  defp decode_sse(buffer, acc) do
    buffer = String.replace(buffer, "\r\n", "\n")
    {frames, rest} = split_frames(buffer)
    Enum.reduce(frames, %{acc | buffer: rest}, &decode_frame/2)
  end

  defp split_frames(buffer) do
    parts = String.split(buffer, "\n\n")

    if String.ends_with?(buffer, "\n\n") do
      {Enum.reject(parts, &(&1 == "")), ""}
    else
      {Enum.drop(parts, -1), List.last(parts) || ""}
    end
  end

  defp decode_frame(frame, acc) do
    {event, data_lines} =
      frame
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {event, data_lines} ->
        cond do
          String.starts_with?(line, "event:") ->
            {line |> String.replace_prefix("event:", "") |> String.trim(), data_lines}

          String.starts_with?(line, "data:") ->
            data = line |> String.replace_prefix("data:", "") |> String.trim_leading()
            {event, [data | data_lines]}

          true ->
            {event, data_lines}
        end
      end)

    data = data_lines |> Enum.reverse() |> Enum.join("\n")

    cond do
      data == "" or data == "[DONE]" ->
        acc

      true ->
        case Jason.decode(data) do
          {:ok, payload} when is_map(payload) ->
            handle_event(event || payload["type"], payload, acc)

          {:ok, _malformed_payload} ->
            put_container_error(acc, :payload)

          {:error, _error} when is_nil(acc.stream_error) ->
            %{
              acc
              | stream_error:
                  Tool.error(:invalid_response, "Anthropic SSE data was not valid JSON.", %{
                    reason: :invalid_json
                  })
            }

          {:error, _error} ->
            acc
        end
    end
  end

  defp handle_event(_event, _payload, %{stream_error: %{ok: false}} = acc), do: acc

  defp handle_event("message_start", payload, acc) do
    case Map.get(payload, "message") do
      nil -> apply_message_start(%{}, payload, acc)
      message when is_map(message) -> apply_message_start(message, payload, acc)
      _malformed_message -> put_container_error(acc, :message)
    end
  end

  defp handle_event("content_block_start", payload, acc) do
    case Map.get(payload, "content_block") do
      nil -> put_content_block(payload["index"], %{}, acc)
      block when is_map(block) -> put_content_block(payload["index"], block, acc)
      _malformed_block -> put_container_error(acc, :content_block)
    end
  end

  defp handle_event("content_block_delta", payload, acc) do
    case Map.get(payload, "delta") do
      nil ->
        acc

      delta when is_map(delta) ->
        apply_content_block_delta(delta, payload["index"], acc)

      _malformed_delta ->
        put_container_error(acc, :delta)
    end
  end

  defp handle_event("content_block_stop", payload, acc) do
    finalize_block(acc, payload["index"])
  end

  defp handle_event("message_delta", payload, acc) do
    case Map.get(payload, "delta") do
      nil ->
        apply_message_delta(%{}, payload, acc)

      delta when is_map(delta) ->
        apply_message_delta(delta, payload, acc)

      _malformed_delta ->
        acc
        |> put_usage(payload["usage"])
        |> Map.put(:stop_reason, :invalid_terminal_evidence)
        |> Map.put(:stop_details, nil)
    end
  end

  defp handle_event("message_stop", _payload, acc), do: acc

  defp handle_event("error", payload, acc) do
    error = payload["error"] || payload
    stream_error = classify_anthropic_error(acc.status || 200, error, acc.headers)

    if acc.delivered_output do
      %{acc | stream_error: force_non_retryable(stream_error)}
    else
      %{acc | stream_error: stream_error}
    end
  end

  defp handle_event(_event, _payload, acc), do: acc

  defp apply_message_start(message, payload, acc) do
    usage = usage_or_fallback(message["usage"], payload["usage"])
    model = message["model"] || payload["model"] || acc.model

    acc
    |> put_usage(usage)
    |> Map.put(:model, model)
    |> put_provider_metadata("model", model)
  end

  defp apply_content_block_delta(delta, index, acc) do
    case delta do
      %{"type" => "text_delta"} = delta ->
        apply_binary_delta(acc, delta, "text", :text, &append_text/2)

      %{"type" => "thinking_delta"} = delta ->
        case thinking_delta_text(delta) do
          {:ok, text} -> append_thinking(acc, index, text)
          {:error, field} -> put_binary_field_error(acc, field)
        end

      %{"type" => "signature_delta"} = delta ->
        case binary_field(delta, "signature", :signature) do
          {:ok, signature} -> append_block_binary(acc, index, "signature", signature, :signature)
          {:error, field} -> put_binary_field_error(acc, field)
        end

      %{"type" => "input_json_delta"} = delta ->
        apply_binary_delta(acc, delta, "partial_json", :partial_json, fn current, partial_json ->
          update_block(current, index, fn block_state ->
            Map.update!(block_state, :input_json, &(&1 <> partial_json))
          end)
        end)

      _delta ->
        acc
    end
  end

  defp put_content_block(index, block, acc) do
    with {:ok, _thinking} <- binary_field(block, "thinking", :thinking),
         {:ok, _signature} <- binary_field(block, "signature", :signature) do
      blocks = Map.put(acc.blocks, index, %{block: block, input_json: ""})
      %{acc | blocks: blocks}
    else
      {:error, field} -> put_binary_field_error(acc, field)
    end
  end

  defp apply_message_delta(delta, payload, acc) do
    usage = usage_or_fallback(payload["usage"], delta["usage"])

    stop_reason =
      if acc.stop_reason == :invalid_terminal_evidence do
        :invalid_terminal_evidence
      else
        delta["stop_reason"] || payload["stop_reason"] || acc.stop_reason
      end

    acc
    |> put_usage(usage)
    |> Map.put(:stop_reason, stop_reason)
    |> Map.put(
      :stop_details,
      delta["stop_details"] || payload["stop_details"] || acc.stop_details
    )
  end

  defp append_text(acc, ""), do: acc

  defp append_text(acc, text) do
    acc.on_delta.({:text_delta, text})
    %{acc | text: acc.text <> text, delivered_output: true}
  end

  defp append_thinking(acc, _index, ""), do: acc

  defp append_thinking(acc, index, text) do
    case append_block_binary(acc, index, "thinking", text, :thinking) do
      %{stream_error: %{ok: false}} = failed ->
        failed

      updated ->
        updated.on_delta.({:reasoning_delta, text})

        updated
        |> Map.update!(:reasoning, &(&1 <> text))
        |> Map.put(:delivered_output, true)
    end
  end

  defp apply_binary_delta(acc, container, key, field, fun) do
    case binary_field(container, key, field) do
      {:ok, value} -> fun.(acc, value)
      {:error, invalid_field} -> put_binary_field_error(acc, invalid_field)
    end
  end

  defp thinking_delta_text(delta) do
    case Map.fetch(delta, "thinking") do
      {:ok, nil} -> binary_field(delta, "text", :text)
      :error -> binary_field(delta, "text", :text)
      {:ok, thinking} when is_binary(thinking) -> {:ok, thinking}
      {:ok, _malformed_thinking} -> {:error, :thinking}
    end
  end

  defp binary_field(container, key, field) do
    case Map.fetch(container, key) do
      :error -> {:ok, ""}
      {:ok, nil} -> {:ok, ""}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _malformed_value} -> {:error, field}
    end
  end

  defp append_block_binary(acc, index, key, value, field) do
    block_state = Map.get(acc.blocks, index, %{block: %{}, input_json: ""})

    case binary_field(block_state.block, key, field) do
      {:ok, current} ->
        updated_state = put_in(block_state, [:block, key], current <> value)
        %{acc | blocks: Map.put(acc.blocks, index, updated_state)}

      {:error, invalid_field} ->
        put_binary_field_error(acc, invalid_field)
    end
  end

  defp update_block(acc, index, fun) do
    blocks = Map.update(acc.blocks, index, fun.(%{block: %{}, input_json: ""}), fun)
    %{acc | blocks: blocks}
  end

  defp finalize_block(acc, index) do
    case Map.get(acc.blocks, index) do
      nil ->
        acc

      %{block: %{"type" => type} = block} when type in ["thinking", "redacted_thinking"] ->
        acc
        |> Map.update!(:blocks, &Map.delete(&1, index))
        |> Map.update!(:output_items, &(&1 ++ [{:reasoning, block}]))

      %{block: %{"type" => "tool_use"} = block, input_json: input_json} ->
        with {:ok, args} <- parse_tool_input(input_json, block["input"]),
             {:ok, call} <- ToolCall.from_map(block["id"], block["name"], args) do
          acc
          |> Map.update!(:blocks, &Map.delete(&1, index))
          |> Map.update!(:output_items, &(&1 ++ [{:function_call, call}]))
        else
          {:error, error} ->
            %{acc | stream_error: error}
        end

      _other ->
        acc
    end
  end

  defp parse_tool_input("", input) when is_map(input) and not is_struct(input), do: {:ok, input}
  defp parse_tool_input("", _input), do: {:error, invalid_tool_input(:missing_json_object)}

  defp parse_tool_input(input_json, _input) do
    case Jason.decode(input_json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _decoded} ->
        {:error, invalid_tool_input(:non_object)}

      {:error, _error} ->
        {:error, invalid_tool_input(:invalid_json)}
    end
  end

  defp invalid_tool_input(reason) do
    Tool.error(:invalid_response, "Anthropic tool_use input must be a JSON object.", %{
      field: :arguments,
      reason: reason
    })
  end

  defp put_usage(acc, nil), do: acc

  defp put_usage(acc, usage) when is_map(usage) do
    usage = stringify_keys(usage)
    %{acc | usage: Map.merge(acc.usage || %{}, usage)}
  end

  defp put_usage(acc, _malformed_usage), do: acc

  defp usage_or_fallback(nil, fallback), do: fallback
  defp usage_or_fallback(usage, _fallback), do: usage

  defp put_container_error(%{stream_error: %{ok: false}} = acc, _field), do: acc

  defp put_container_error(acc, field) do
    error =
      Tool.error(:invalid_response, "Anthropic SSE field must be a JSON object.", %{
        field: field,
        reason: :non_object,
        retryable: false
      })

    %{acc | stream_error: error}
  end

  defp put_binary_field_error(%{stream_error: %{ok: false}} = acc, _field), do: acc

  defp put_binary_field_error(acc, field) do
    error =
      Tool.error(:invalid_response, "Anthropic SSE field must be a string.", %{
        field: field,
        reason: :non_binary,
        retryable: false
      })

    %{acc | stream_error: error}
  end

  defp put_provider_metadata(acc, _key, nil), do: acc

  defp put_provider_metadata(acc, key, value),
    do: %{acc | provider_metadata: Map.put(acc.provider_metadata, key, value)}

  defp complete_stream(%{status: status} = acc)
       when is_integer(status) and (status < 200 or status >= 300) do
    body = ErrBody.body(acc.err_body)

    {:error, classify_http_error(status, body, acc.headers, ErrBody.truncated?(acc.err_body))}
  end

  defp complete_stream(%{stream_error: %{ok: false} = error}), do: {:error, error}

  defp complete_stream(acc) do
    case acc.stop_reason do
      "end_turn" ->
        {:ok, finalize(acc, :stop, OutputTruncation.not_truncated("end_turn"))}

      "stop_sequence" ->
        {:ok, finalize(acc, :stop, OutputTruncation.not_truncated("stop_sequence"))}

      "tool_use" ->
        finish_reason = if has_function_call?(acc.output_items), do: :tool_calls, else: :stop

        {:ok, finalize(acc, finish_reason, OutputTruncation.not_truncated("tool_use"))}

      "max_tokens" ->
        finish_reason = if has_function_call?(acc.output_items), do: :tool_calls, else: :stop

        {:ok,
         acc
         |> put_provider_metadata("stop_reason", "max_tokens")
         |> put_provider_metadata("truncated", true)
         |> finalize(
           finish_reason,
           OutputTruncation.truncated(:provider_output_limit, "max_tokens")
         )}

      "model_context_window_exceeded" ->
        finish_reason = if has_function_call?(acc.output_items), do: :tool_calls, else: :stop

        {:ok,
         acc
         |> put_provider_metadata("stop_reason", "model_context_window_exceeded")
         |> put_provider_metadata("truncated", true)
         |> finalize(
           finish_reason,
           OutputTruncation.truncated(
             :provider_context_window_limit,
             "model_context_window_exceeded"
           )
         )}

      "refusal" ->
        {:error,
         Tool.error(:provider_refusal, "Anthropic refused to complete the request.", %{
           stop_reason: "refusal",
           stop_details: acc.stop_details || %{},
           retryable: false,
           model: acc.model
         })}

      nil ->
        {:ok, finalize(acc, :stop, OutputTruncation.unknown(:missing_terminal_evidence))}

      other when is_binary(other) ->
        evidence = OutputTruncation.unknown(:unrecognized_terminal_reason, other)
        safe_unmapped_reason = OutputTruncation.provider_reason(evidence)

        {:ok,
         acc
         |> put_provider_metadata("unmapped_stop_reason", safe_unmapped_reason)
         |> finalize(:stop, evidence)}

      _other ->
        {:ok, finalize(acc, :stop, OutputTruncation.unknown(:invalid_evidence))}
    end
  end

  defp has_function_call?(output_items) do
    Enum.any?(output_items, &match?({:function_call, _}, &1))
  end

  defp finalize(acc, finish_reason, output_truncation) do
    %{
      text: acc.text,
      reasoning: acc.reasoning,
      reasoning_items: reasoning_items(acc.output_items),
      function_calls: function_calls(acc.output_items),
      output_items: acc.output_items,
      usage: acc.usage,
      usage_summary: usage_summary(acc.usage, acc.model),
      provider_metadata: acc.provider_metadata,
      finish_reason: finish_reason,
      output_truncation: output_truncation
    }
  end

  defp partial_metadata?(metadata) when is_map(metadata),
    do: get_field(metadata, :partial) == true

  defp partial_metadata?(_metadata), do: false

  defp reasoning_items(output_items) do
    for {:reasoning, block} <- output_items, do: block
  end

  defp function_calls(output_items) do
    for {:function_call, call} <- output_items, do: call
  end

  defp usage_summary(usage, model) do
    usage = usage || %{}
    input_tokens = int(usage["input_tokens"])
    output_tokens = int(usage["output_tokens"])
    creation_tokens = int(usage["cache_creation_input_tokens"])
    read_tokens = int(usage["cache_read_input_tokens"])

    total_tokens =
      int(usage["total_tokens"], input_tokens + creation_tokens + read_tokens + output_tokens)

    cache =
      %{"creation_tokens" => creation_tokens, "read_tokens" => read_tokens}
      |> maybe_put_cache_ttl(usage, "ephemeral_5m_input_tokens")
      |> maybe_put_cache_ttl(usage, "ephemeral_1h_input_tokens")

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => total_tokens,
      "model" => model,
      "cache" => cache,
      "cached_tokens" => read_tokens,
      "cache_hit_rate" =>
        cache_hit_rate(read_tokens, input_tokens + creation_tokens + read_tokens)
    }
  end

  defp int(value, default \\ 0)
  defp int(value, _default) when is_integer(value), do: value
  defp int(value, default) when is_binary(value), do: parse_int(value, default)
  defp int(_value, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> default
    end
  end

  defp cache_hit_rate(_read_tokens, 0), do: 0
  defp cache_hit_rate(read_tokens, input_tokens), do: read_tokens / input_tokens

  defp force_non_retryable(%{error: error} = envelope) when is_map(error) do
    put_in(envelope, [:error, :details, :retryable], false)
  end

  defp classify_http_error(status, body, headers, truncated?) do
    error = do_classify_http_error(status, body, headers)

    if truncated? do
      update_in(error, [:error, :details], &Map.put(&1, :err_body_truncated, true))
    else
      error
    end
  end

  defp do_classify_http_error(status, body, headers) do
    error = decode_error_body(body)
    classify_anthropic_error(status, error, headers)
  end

  defp classify_anthropic_error(status, error, headers) do
    type = error_type(error)
    message = error_message(error, status)
    retry_after_ms = retry_after_ms(headers)

    details =
      %{
        status: status,
        type: type,
        retryable: retryable_error?(status, type)
      }
      |> maybe_detail(:retry_after_ms, retry_after_ms)
      |> maybe_detail(:anthropic_error, error)

    cond do
      status == 429 or type == "rate_limit_error" ->
        Tool.error(:rate_limited, message, Map.put(details, :retryable, true))

      status in [400, 413] and type == "invalid_request_error" and overflow_message?(message) ->
        Tool.error(:context_overflow, message, Map.put(details, :retryable, false))

      true ->
        Tool.error(:provider_http_error, message, details)
    end
  end

  defp decode_error_body(""), do: %{}
  defp decode_error_body(nil), do: %{}

  defp decode_error_body(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_map(error) -> error
      {:ok, decoded} -> decoded
      {:error, _} -> %{"message" => body}
    end
  end

  defp error_type(%{"type" => type}), do: type
  defp error_type(%{type: type}), do: type
  defp error_type(_), do: nil

  defp error_message(%{"message" => message}, _status) when is_binary(message), do: message
  defp error_message(%{message: message}, _status) when is_binary(message), do: message
  defp error_message(_error, status), do: "Anthropic provider returned HTTP #{status}."

  defp overflow_message?(message) do
    Regex.match?(
      ~r/(context_length_exceeded|context window|maximum context|too many tokens|prompt is too long|input is too long)/i,
      message
    )
  end

  defp retryable_error?(status, type) do
    status in [500, 502, 503, 504, 529] or type in ["overloaded_error", "api_error"]
  end

  defp maybe_detail(details, _key, nil), do: details
  defp maybe_detail(details, key, value), do: Map.put(details, key, value)

  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == "retry-after", do: parse_retry_after(value)
    end)
  end

  defp parse_retry_after(value) do
    case Float.parse(to_string(value)) do
      {seconds, _rest} when seconds >= 0 -> round(seconds * 1000)
      _ -> nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
