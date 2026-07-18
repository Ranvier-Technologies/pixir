defmodule Pixir.Provider.ResponsesExtensions do
  @moduledoc """
  Responses wire and strict-open runtime policy.

  Request shaping is derived only from the frozen `ResponsesBackend` snapshot; it
  never consults a model, endpoint, Registry, or prior request. The strict-open path
  validates every known event against the generated pinned schema before applying the
  exact event-family-owned local correlation limits and portable output policy;
  same-named additional properties outside those owners remain ignored, and neither
  layer retains remote payload values. The first `open_responses` profile has an empty
  extension set and fixed reasoning/nonportable-content boundaries, while the default
  ChatGPT/Codex wire keeps its ordered policy and reducer.
  """

  alias Pixir.Provider.{HostedTools, OpenResponsesSchema}
  alias Pixir.Providers.ResponsesBackend
  alias Pixir.Tool

  @extension_ids [
    :prompt_cache_key,
    :prompt_cache_retention,
    :reasoning_encrypted_content,
    :hosted_tool_includes
  ]
  @message_roles ~w(user developer system assistant)
  @known_stream_event_types ~w(
    error
    response.created
    response.in_progress
    response.queued
    response.output_item.added
    response.output_item.done
    response.content_part.added
    response.content_part.done
    response.output_text.delta
    response.output_text.done
    response.output_text.annotation.added
    response.function_call_arguments.delta
    response.function_call_arguments.done
    response.refusal.delta
    response.refusal.done
    response.reasoning.delta
    response.reasoning.done
    response.reasoning_summary_part.added
    response.reasoning_summary_part.done
    response.reasoning_summary_text.delta
    response.reasoning_summary_text.done
    response.completed
    response.incomplete
    response.failed
  )
  @output_coordinate_event_types ~w(
    response.content_part.added
    response.content_part.done
    response.output_text.delta
    response.output_text.done
    response.output_text.annotation.added
    response.function_call_arguments.delta
    response.function_call_arguments.done
  )
  @content_coordinate_event_types ~w(
    response.content_part.added
    response.content_part.done
    response.output_text.delta
    response.output_text.done
    response.output_text.annotation.added
  )

  @doc "Validate requested capabilities before routing, body construction, Auth, or transport."
  @spec validate_request(ResponsesBackend.t(), map(), term()) :: :ok | {:error, map()}
  def validate_request(%ResponsesBackend{} = backend, request, reasoning_effort)
      when is_map(request) and not is_struct(request) do
    case ResponsesBackend.mode(backend) do
      :chatgpt_codex ->
        :ok

      :open_responses ->
        with :ok <- reject_reasoning(reasoning_effort),
             {:ok, hosted_tools} <- HostedTools.from_request(request),
             :ok <- reject_hosted_tools(hosted_tools) do
          :ok
        else
          {:error, %{kind: _kind} = error} -> {:error, %{ok: false, error: error}}
          {:error, %{error: _error} = envelope} -> {:error, envelope}
        end
    end
  end

  def validate_request(_backend, _request, _reasoning_effort),
    do:
      {:error,
       Tool.error(:invalid_config, "The Responses request capability context is invalid.", %{
         field: :responses_backend,
         reason: :invalid_capability_context
       })}

  @doc "Return the fixed ordered non-auth headers for a backend mode."
  @spec headers(ResponsesBackend.t()) :: [{String.t(), String.t()}]
  def headers(%ResponsesBackend{} = backend) do
    case ResponsesBackend.mode(backend) do
      :chatgpt_codex ->
        [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"},
          {"openai-beta", "responses=experimental"},
          {"originator", "pixir"}
        ]

      :open_responses ->
        [
          {"content-type", "application/json"},
          {"accept", "text/event-stream"}
        ]
    end
  end

  @doc "Project the folded input without changing content bytes or non-message items."
  @spec project_input(ResponsesBackend.t(), [map()]) :: [map()]
  def project_input(%ResponsesBackend{} = backend, items) when is_list(items) do
    case ResponsesBackend.mode(backend) do
      :chatgpt_codex -> items
      :open_responses -> Enum.flat_map(items, &project_open_item/1)
    end
  end

  @doc "Whether the immutable snapshot permits a typed request extension."
  @spec allowed?(ResponsesBackend.t(), atom()) :: boolean()
  def allowed?(%ResponsesBackend{} = backend, extension) when extension in @extension_ids,
    do: MapSet.member?(ResponsesBackend.request_extensions(backend), extension)

  def allowed?(_backend, _extension), do: false

  @doc "Safe sorted extension ids applied by this backend snapshot."
  @spec applied_ids(ResponsesBackend.t()) :: [String.t()]
  def applied_ids(%ResponsesBackend{} = backend) do
    @extension_ids
    |> Enum.filter(&allowed?(backend, &1))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc "Safe sorted extension ids omitted by this backend snapshot."
  @spec omitted_ids(ResponsesBackend.t()) :: [String.t()]
  def omitted_ids(%ResponsesBackend{} = backend) do
    @extension_ids
    |> Enum.reject(&allowed?(backend, &1))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  @doc "Validate pinned schema, local limits, and portability for one strict-open event."
  @spec validate_stream_event(map()) ::
          {:ok, :known | :unknown}
          | {:error, atom()}
          | {:unsupported, :reasoning | :nonportable_output_item | :nonportable_content}
  def validate_stream_event(%{"type" => type} = event) when is_binary(type) do
    if type in @known_stream_event_types do
      with :ok <- OpenResponsesSchema.validate(type, event),
           :ok <- local_event_limits(type, event),
           :ok <- validate_known_event(type, event) do
        {:ok, :known}
      end
    else
      {:ok, :unknown}
    end
  end

  def validate_stream_event(_event), do: {:error, :invalid_event_shape}

  defp validate_known_event("error", _event), do: :ok

  defp validate_known_event(type, event)
       when type in [
              "response.created",
              "response.in_progress",
              "response.queued",
              "response.completed",
              "response.incomplete",
              "response.failed"
            ] do
    portable_response_output(event["response"]["output"])
  end

  defp validate_known_event(type, event)
       when type in ["response.output_item.added", "response.output_item.done"] do
    portable_stream_output_item(event["item"])
  end

  defp validate_known_event(type, event)
       when type in ["response.content_part.added", "response.content_part.done"] do
    portable_content_part(event["part"])
  end

  defp validate_known_event(type, _event)
       when type in ["response.refusal.delta", "response.refusal.done"],
       do: {:unsupported, :nonportable_content}

  defp validate_known_event(type, _event)
       when type in [
              "response.reasoning.delta",
              "response.reasoning.done",
              "response.reasoning_summary_part.added",
              "response.reasoning_summary_part.done",
              "response.reasoning_summary_text.delta",
              "response.reasoning_summary_text.done"
            ],
       do: {:unsupported, :reasoning}

  defp validate_known_event(_type, _event), do: :ok

  defp local_event_limits(type, event) do
    with :ok <- non_negative_integer(event["sequence_number"]),
         :ok <-
           owned_non_negative_integer(type, event, "output_index", @output_coordinate_event_types),
         :ok <-
           owned_non_negative_integer(
             type,
             event,
             "content_index",
             @content_coordinate_event_types
           ),
         :ok <- owned_nonempty_binary(type, event, "item_id", @output_coordinate_event_types) do
      :ok
    end
  end

  defp owned_non_negative_integer(type, event, field, owners) do
    if type in owners, do: non_negative_integer(event[field]), else: :ok
  end

  defp owned_nonempty_binary(type, event, field, owners) do
    if type in owners, do: nonempty_binary(event[field]), else: :ok
  end

  defp portable_response_output(items) when is_list(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case portable_output_item(item) do
        :ok -> {:cont, :ok}
        rejection -> {:halt, rejection}
      end
    end)
  end

  defp portable_stream_output_item(nil), do: :ok
  defp portable_stream_output_item(item), do: portable_output_item(item)

  defp portable_output_item(nil), do: {:error, :invalid_event_shape}

  defp portable_output_item(%{"type" => "message"} = item) do
    with :ok <- nonempty_binary(item["id"]),
         :ok <- portable_message_content(item["content"]) do
      :ok
    else
      {:unsupported, _capability} = rejection -> rejection
      _ -> {:error, :invalid_event_shape}
    end
  end

  defp portable_output_item(%{"type" => "function_call"} = item) do
    with :ok <- nonempty_binary(item["id"]),
         :ok <- nonempty_binary(item["call_id"]),
         :ok <- nonempty_binary(item["name"]) do
      :ok
    else
      _ -> {:error, :invalid_event_shape}
    end
  end

  defp portable_output_item(%{"type" => "reasoning"}), do: {:unsupported, :reasoning}

  defp portable_output_item(%{"type" => type})
       when type in ["function_call_output", "compaction"],
       do: {:unsupported, :nonportable_output_item}

  defp portable_output_item(_item), do: {:error, :invalid_event_shape}

  defp portable_message_content(parts) do
    Enum.reduce_while(parts, :ok, fn part, :ok ->
      case portable_content_part(part) do
        :ok -> {:cont, :ok}
        rejection -> {:halt, rejection}
      end
    end)
  end

  defp portable_content_part(%{"type" => type}) when type in ~w(reasoning_text summary_text),
    do: {:unsupported, :reasoning}

  defp portable_content_part(%{"type" => type})
       when type in ~w(refusal input_image input_file input_video),
       do: {:unsupported, :nonportable_content}

  defp portable_content_part(%{"type" => type})
       when type in ~w(output_text text input_text),
       do: :ok

  defp portable_content_part(_part), do: {:error, :invalid_event_shape}

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(value) when is_float(value) and value >= 0 do
    if value == Float.floor(value), do: :ok, else: {:error, :invalid_event_shape}
  end

  defp non_negative_integer(_value), do: {:error, :invalid_event_shape}
  defp nonempty_binary(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp nonempty_binary(_value), do: {:error, :invalid_event_shape}

  defp reject_reasoning(nil), do: :ok

  defp reject_reasoning(_reasoning_effort) do
    {:error,
     Tool.error(
       :unsupported_backend_capability,
       "The selected Responses backend does not support requested reasoning.",
       %{backend_mode: :open_responses, capability: :reasoning}
     )}
  end

  defp reject_hosted_tools([]), do: :ok

  defp reject_hosted_tools(_hosted_tools) do
    {:error,
     Tool.error(
       :unsupported_backend_capability,
       "The selected Responses backend does not support Provider-hosted tools.",
       %{backend_mode: :open_responses, capability: :provider_hosted_tools}
     )}
  end

  defp project_open_item(%{"type" => "reasoning"}), do: []
  defp project_open_item(%{"type" => type}) when type in ["thinking", "redacted_thinking"], do: []

  defp project_open_item(%{"role" => role, "content" => _content} = item)
       when role in @message_roles do
    [Map.put_new(item, "type", "message")]
  end

  defp project_open_item(item), do: [item]
end
