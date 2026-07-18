defmodule Pixir.Renderer do
  @moduledoc """
  The first thin front-end over the event bus (ADR 0004, decision D-05): a stdout
  subscriber that pattern-matches on `event.type`. It validates the seam — the core
  needs no changes for a new front-end.

  Channel discipline (ADR 0005):

    * **stdout** — the model's answer: streamed `text_delta`s and the final newline.
    * **stderr** — activity and diagnostics: tool calls/results, reasoning, status.

  `render/1` is the pure mapping from an Event to writes (`[{:stdout | :stderr, io}]`),
  so it is unit-testable. `consume_until_done/1` owns one canonical Session epoch,
  performing writes until that Session emits terminal `status` (`"done"` / `"error"`).
  The Session may be explicit in `:session_id` or safely derived from the first
  canonical Event; foreign-Session Events never contaminate the epoch.
  """

  @idle_timeout 120_000
  @output_warning_limit 256

  @doc "Map an Event to a list of `{:stdout | :stderr, iodata}` writes."
  @spec render(map()) :: [{:stdout | :stderr, iodata()}]
  def render(%{type: :text_delta, data: %{"chunk" => chunk}}), do: [{:stdout, chunk}]
  def render(%{type: :reasoning_delta, data: %{"chunk" => chunk}}), do: [{:stderr, chunk}]
  def render(%{type: :assistant_message}), do: [{:stdout, "\n"}]

  def render(%{type: :provider_usage} = event) do
    case Pixir.Provider.OutputTruncationSummary.warning(event) do
      nil -> []
      warning -> [{:stderr, output_truncation_warning(warning)}]
    end
  end

  def render(%{type: :tool_call, data: %{"name" => name, "args" => args}}),
    do: [{:stderr, "\n› #{name} #{compact(args)}\n"}]

  def render(%{type: :tool_result, data: data}), do: [{:stderr, tool_result_line(data)}]

  def render(%{type: :status, data: %{"status" => status}})
      when status in ["error", "interrupted"],
      do: [{:stderr, "[#{status}]\n"}]

  # Context-pressure output (ADR 0020) is diagnostics for the human, never the
  # model: stderr only, from an ephemeral event that the Log cannot contain.
  # Routine snapshots feed presenters such as T3; terminal CLI should stay quiet
  # until the event is an advisory/warning/recovery notice.
  def render(%{type: :context_pressure, data: %{"presentation" => "snapshot"}}), do: []

  def render(%{type: :context_pressure, data: %{"tier" => "advisory"} = data}),
    do: [{:stderr, "[context #{percent(data)} of the #{data["model"]} window]\n"}]

  def render(%{type: :context_pressure, data: %{"tier" => tier} = data})
      when tier in ["warning", "critical"],
      do: [{:stderr, context_warning(data)}]

  def render(%{type: :context_pressure, data: %{"tier" => "recovery", "message" => message}})
      when is_binary(message),
      do: [{:stderr, "[context] #{message}\n"}]

  def render(_event), do: []

  @doc "Render one Provider-output truncation warning without changing model text."
  @spec output_truncation_warning(map()) :: iodata()
  def output_truncation_warning(warning) do
    "warning: provider output was truncated (reason=#{warning["reason"]}, " <>
      "call=#{warning["provider_usage_event_id"]}); showing provider text exactly as received\n"
  end

  @doc "Render the terminal summary when a Presenter suppressed warnings over its cap."
  @spec output_truncation_suppression(non_neg_integer(), non_neg_integer()) :: iodata()
  def output_truncation_suppression(total, shown) do
    "warning: additional provider-output truncation notices suppressed " <>
      "(total=#{total}, shown=#{shown})\n"
  end

  @doc """
  Receive and render Events for the calling (already-subscribed) process until a
  terminal status. Returns `:ok` or `:timeout` after `:idle_timeout` ms of silence.
  """
  @spec consume_until_done(keyword()) :: :ok | :timeout
  def consume_until_done(opts \\ []) do
    timeout = Keyword.get(opts, :idle_timeout, @idle_timeout)

    consume_until_done(opts, timeout, %{
      session_id: explicit_session_id(opts),
      output_warning_total: 0,
      output_warning_shown: 0,
      output_warning_keys: MapSet.new(),
      output_latest_order_key: nil
    })
  end

  defp consume_until_done(opts, timeout, warning_state) do
    receive do
      {:pixir_event, event} ->
        case accept_epoch_event(event, warning_state) do
          {:ok, warning_state} ->
            warning_state = render_bounded(event, warning_state)

            if terminal?(event) do
              maybe_write_suppression(warning_state)
              :ok
            else
              consume_until_done(opts, timeout, warning_state)
            end

          :foreign ->
            consume_until_done(opts, timeout, warning_state)
        end
    after
      timeout ->
        maybe_write_suppression(warning_state)
        :timeout
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp terminal?(%{type: :status, data: %{"status" => status}})
       when status in ["done", "error", "interrupted"],
       do: true

  defp terminal?(_event), do: false

  defp explicit_session_id(opts) do
    case Keyword.get(opts, :session_id) do
      session_id when is_binary(session_id) and byte_size(session_id) > 0 -> session_id
      _missing_or_invalid -> nil
    end
  end

  defp accept_epoch_event(event, %{session_id: nil} = state) do
    case event_session_id(event) do
      session_id when is_binary(session_id) and byte_size(session_id) > 0 ->
        {:ok, %{state | session_id: session_id}}

      _missing ->
        :foreign
    end
  end

  defp accept_epoch_event(event, state) do
    if event_session_id(event) == state.session_id, do: {:ok, state}, else: :foreign
  end

  defp event_session_id(event),
    do: Map.get(event, :session_id, Map.get(event, "session_id"))

  defp render_bounded(%{type: :provider_usage} = event, state) do
    case Pixir.Provider.OutputTruncationSummary.warning(event) do
      nil ->
        state

      warning ->
        track_output_warning(event, warning, state)
    end
  end

  defp render_bounded(%{type: :assistant_message} = event, state) do
    Enum.each(render(event), &write/1)

    case Pixir.Provider.OutputTruncationSummary.assistant_fallback(event) do
      {:ok, _projection, warning} -> track_output_warning(event, warning, state)
      :error -> state
    end
  end

  defp render_bounded(event, state) do
    Enum.each(render(event), &write/1)
    state
  end

  defp maybe_write_suppression(%{
         output_warning_total: total,
         output_warning_shown: shown
       })
       when total > shown do
    write({:stderr, output_truncation_suppression(total, shown)})
  end

  defp maybe_write_suppression(_state), do: :ok

  defp track_output_warning(event, warning, state) do
    session_id = Map.get(event, :session_id, Map.get(event, "session_id"))
    event_id = warning["provider_usage_event_id"]
    order_key = {warning["provider_usage_seq"], event_id}
    key = {session_id, event_id}

    cond do
      MapSet.member?(state.output_warning_keys, key) ->
        state

      not is_nil(state.output_latest_order_key) and order_key <= state.output_latest_order_key ->
        state

      true ->
        total = state.output_warning_total + 1

        state = %{
          state
          | output_warning_total: total,
            output_latest_order_key: order_key
        }

        if state.output_warning_shown < @output_warning_limit do
          write({:stderr, output_truncation_warning(warning)})

          %{
            state
            | output_warning_shown: state.output_warning_shown + 1,
              output_warning_keys: MapSet.put(state.output_warning_keys, key)
          }
        else
          state
        end
    end
  end

  @doc "Perform a single `{:stdout | :stderr, iodata}` write (used by front-ends)."
  @spec write({:stdout | :stderr, iodata()}) :: :ok
  def write({:stdout, io}), do: IO.write(io)
  def write({:stderr, io}), do: IO.write(:stderr, io)

  defp context_warning(data) do
    header =
      "[context #{percent(data)} of the #{data["model"]} window] " <>
        "WARNING: approaching the model context limit.\n"

    actions =
      data
      |> Map.get("next_actions", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map_join("", fn action -> "  next: #{action["command"]}\n" end)

    header <> actions
  end

  defp percent(%{"ratio" => ratio}) when is_number(ratio), do: "#{round(ratio * 100)}%"
  defp percent(_data), do: "?%"

  defp tool_result_line(%{"ok" => true}), do: "  ok\n"
  defp tool_result_line(%{"ok" => false, "error" => %{"kind" => kind}}), do: "  error (#{kind})\n"
  defp tool_result_line(%{"dry_run" => true}), do: "  (dry-run)\n"
  defp tool_result_line(_), do: "  done\n"

  defp compact(args) when is_map(args) do
    args
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{truncate_arg(v)}" end)
  end

  defp compact(args), do: inspect(args)

  defp truncate_arg(v) do
    s = if is_binary(v), do: v, else: inspect(v)
    if String.length(s) > 60, do: String.slice(s, 0, 57) <> "...", else: s
  end
end
