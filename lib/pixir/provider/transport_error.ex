defmodule Pixir.Provider.TransportError do
  @moduledoc """
  Secret-safe classification for failures crossing the Provider transport boundary.

  Transport failures may contain request arguments, stack frames, headers, endpoint
  paths, or arbitrary adapter terms. This module deliberately projects only a small,
  fixed vocabulary; callers must never `inspect/1` an untrusted transport reason into
  an error, Log, diagnostic, or Provider metadata field.
  """

  alias Pixir.Tool

  @safe_reasons [
    :badarg,
    :case_clause,
    :closed,
    :econnrefused,
    :ehostunreach,
    :enetunreach,
    :finch_transport_error,
    :function_clause,
    :match_error,
    :nxdomain,
    :noproc,
    :shutdown,
    :stream_callback_failed,
    :timeout,
    :transport_failure,
    :transport_process_exited
  ]

  @websocket_kinds [
    :invalid_endpoint,
    :websocket_call_timeout,
    :websocket_closed,
    :websocket_connect_failed,
    :websocket_degraded,
    :websocket_failed,
    :websocket_frame_too_large,
    :websocket_handshake_failed,
    :websocket_read_failed,
    :websocket_start_failed,
    :websocket_timeout
  ]

  @safe_transport_labels ["auto", "http_sse", "websocket"]
  @safe_next_actions [
    "check_network_or_provider_status",
    "fall_back_to_full_replay",
    "inspect_session_lifecycle",
    "retry_turn"
  ]
  @safe_continuation_reset_reasons ["caller_timeout", "stream_callback_failed"]

  @doc "Return a bounded reason atom without retaining arbitrary failure data."
  @spec reason(term()) :: atom()
  def reason(%Finch.TransportError{reason: reason}),
    do: safe_reason(reason, :finch_transport_error)

  def reason(%FunctionClauseError{}), do: :function_clause
  def reason(%MatchError{}), do: :match_error
  def reason(%ArgumentError{}), do: :badarg

  def reason({kind, _details}) when kind in [:function_clause, :badarg, :case_clause],
    do: kind

  def reason({kind, _reason}) when kind in [:error, :exit, :throw],
    do: :transport_process_exited

  def reason("stream_callback_failed"), do: :stream_callback_failed
  def reason(reason), do: safe_reason(reason, :transport_failure)

  @doc "Project an arbitrary transport return into a bounded structured error."
  @spec project(term(), keyword()) :: map()
  def project(error, opts \\ [])

  def project(%{error: %{kind: :stream_idle_timeout, details: details}}, _opts)
      when is_map(details) do
    safe_details =
      %{}
      |> maybe_put(:timeout_ms, safe_non_negative_integer(detail(details, :timeout_ms)))
      |> maybe_put(:transport, safe_transport_label(detail(details, :transport)))
      |> Map.put(:next_actions, ["retry_turn", "check_network_or_provider_status"])

    Tool.error(
      :stream_idle_timeout,
      "Provider stream stalled waiting for the next chunk.",
      safe_details
    )
  end

  def project(%{error: %{kind: :network, details: details}}, opts) when is_map(details) do
    details =
      %{reason: reason(detail(details, :reason))}
      |> maybe_put(:transport, safe_transport_label(detail(details, :transport)))
      |> maybe_put(
        :retry_after_ms,
        safe_non_negative_integer(detail(details, :retry_after_ms))
      )
      |> maybe_put(
        :continuation_reset_reason,
        safe_continuation_reset_reason(detail(details, :continuation_reset_reason))
      )
      |> maybe_put(:next_actions, safe_next_actions(detail(details, :next_actions)))
      |> maybe_put(:exit_kind, safe_exit_kind(detail(details, :exit_kind)))
      |> maybe_put(:exit_reason, safe_optional_reason(detail(details, :exit_reason)))
      |> maybe_put_status(opts)

    Tool.error(:network, "provider stream failed", details)
  end

  def project(%{error: %{kind: :provider_http_error, details: details}}, _opts)
      when is_map(details) do
    safe_details =
      %{}
      |> maybe_put(:status, safe_status(detail(details, :status)))
      |> maybe_put(:retryable, safe_boolean(detail(details, :retryable)))
      |> maybe_put(
        :reason,
        safe_provider_http_reason(detail(details, :reason))
      )

    Tool.error(:provider_http_error, "Provider transport returned an error.", safe_details)
  end

  def project(%{error: %{kind: kind, details: details}}, _opts)
      when kind in @websocket_kinds and is_map(details) do
    safe_details =
      %{}
      |> maybe_put(:status, safe_status(detail(details, :status)))
      |> maybe_put(:timeout_ms, safe_non_negative_integer(detail(details, :timeout_ms)))
      |> maybe_put(
        :retry_after_ms,
        safe_non_negative_integer(detail(details, :retry_after_ms))
      )
      |> maybe_put(:bytes, safe_non_negative_integer(detail(details, :bytes)))
      |> maybe_put(:reason, safe_optional_reason(detail(details, :reason)))
      |> maybe_put(
        :continuation_reset_reason,
        safe_continuation_reset_reason(detail(details, :continuation_reset_reason))
      )
      |> maybe_put(:next_actions, safe_next_actions(detail(details, :next_actions)))

    Tool.error(kind, "WebSocket transport failed.", safe_details)
  end

  def project(%{error: %{kind: kind}}, _opts)
      when kind in [:invalid_args, :invalid_provider_request] do
    Tool.error(kind, "Provider transport rejected the request.", %{})
  end

  def project(reason, opts) do
    details =
      %{reason: reason(reason)}
      |> maybe_put_status(opts)

    Tool.error(:network, "provider stream failed", details)
  end

  defp safe_reason(reason, _fallback) when reason in @safe_reasons, do: reason
  defp safe_reason(_reason, fallback), do: fallback

  defp detail(details, key), do: Map.get(details, key) || Map.get(details, Atom.to_string(key))

  defp safe_transport_label(label) when label in @safe_transport_labels, do: label
  defp safe_transport_label(_label), do: nil

  defp safe_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp safe_non_negative_integer(_value), do: nil

  defp safe_status(value) when is_integer(value) and value in 100..999, do: value
  defp safe_status(_value), do: nil

  defp safe_boolean(value) when is_boolean(value), do: value
  defp safe_boolean(_value), do: nil

  defp safe_provider_http_reason("previous_response_not_found"),
    do: "previous_response_not_found"

  defp safe_provider_http_reason(_reason), do: nil

  defp safe_optional_reason(nil), do: nil
  defp safe_optional_reason(value), do: reason(value)

  defp safe_next_actions(actions) when is_list(actions) do
    actions = Enum.filter(actions, &(&1 in @safe_next_actions))
    if actions == [], do: nil, else: actions
  end

  defp safe_next_actions(_actions), do: nil

  defp safe_continuation_reset_reason(reason)
       when reason in @safe_continuation_reset_reasons,
       do: reason

  defp safe_continuation_reset_reason(_reason), do: nil

  defp safe_exit_kind(kind) when kind in [:error, :exit, :throw], do: kind
  defp safe_exit_kind(_kind), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_status(details, opts) do
    if Keyword.has_key?(opts, :status) do
      Map.put(details, :status, safe_status(Keyword.get(opts, :status)))
    else
      details
    end
  end
end
