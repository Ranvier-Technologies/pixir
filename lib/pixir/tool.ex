defmodule Pixir.Tool do
  @moduledoc """
  The Tool behaviour (CONTEXT.md; the Kimojo-shaped contract minus `risk_level`).

  A Tool declares itself via `__tool__/0` and runs via `execute/2`. Per ADR 0005 every
  Tool is also **dry-runnable**: `use Pixir.Tool` injects a default `dry_run/2` that
  reports the planned action without side effects; side-effecting Tools override it
  with a richer (still effect-free) plan.

  ## `__tool__/0`

      %{
        name: "read",
        description: "Read a file from the workspace",
        parameters: %{                       # JSON Schema (string keys)
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      }

  ## `execute/2` and `dry_run/2`

  Receive `args` (a string-keyed map, validated by the Executor) and a `context`
  `%{session_id, workspace, call_id, dry_run}`. They return:

    * `{:ok, result}` — `result` is a string-keyed map; `"output"` (a string) is the
      model-facing payload (token-bounded via `truncate/2`, ADR 0005).
    * `{:error, structured}` — the standard `%{ok: false, error: %{kind, message,
      details}}` envelope (use `error/3`).
  """

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}
  @type context :: %{
          required(:session_id) => String.t(),
          required(:workspace) => String.t(),
          required(:call_id) => String.t(),
          optional(:dry_run) => boolean()
        }
  @type result :: {:ok, map()} | {:error, map()}

  @callback __tool__() :: spec()
  @callback execute(args :: map(), context()) :: result()
  @callback dry_run(args :: map(), context()) :: result()

  @default_max_output 16_000

  defmacro __using__(_opts) do
    quote do
      @behaviour Pixir.Tool

      @impl Pixir.Tool
      def dry_run(args, _context) do
        {:ok, %{"dry_run" => true, "tool" => __tool__().name, "args" => args}}
      end

      defoverridable dry_run: 2
    end
  end

  @typedoc """
  The curated, stable error-`kind` vocabulary (ADR 0005, rule 3). Callers and the model
  branch on these, so the set is documented here as the single source of truth — adding a
  kind is a deliberate change, not an ad-hoc string. Grouped by origin:

    * **tools / executor** — `:invalid_args`, `:unknown_tool`, `:outside_workspace`,
      `:protected_path`, `:not_found`, `:resource_missing`, `:no_match`, `:not_unique`,
      `:read_failed`, `:write_failed`, `:command_failed`, `:timeout`,
      `:permission_denied`, `:write_policy_denied`, `:bash_disabled`, `:detached`,
      `:backpressure`
    * **turn loop** — `:iteration_cap`, `:tool_result_record_failed`,
      `:session_record_unavailable`
    * **log / writer lease** — `:unsafe_state_path`, `:corrupt_log_line`, `:ephemeral_not_loggable`,
      `:log_encode_failed`, `:log_read_failed`, `:log_write_failed`,
      `:session_writer_active`, `:session_writer_stale`,
      `:session_writer_ambiguous`, `:session_writer_lost`
    * **provider** — `:provider_http_error`, `:model_not_supported`, `:usage_limit_reached`,
      `:rate_limited`, `:network`, `:provider_refusal`, `:unsupported_transport`,
      `:unsupported_backend_capability`, `:context_overflow`, `:stream_idle_timeout`,
      `:dangling_tool_call`
    * **auth** — `:not_authenticated`, `:insecure_auth_transport`,
      `:token_request_failed`, `:no_account_id`, `:invalid_response`, `:corrupt_auth`,
      `:auth_read_failed`, `:auth_write_failed`, `:device_auth_failed`,
      `:device_code_unsupported`, `:session_start_failed`
    * **cli / stdin** — `:no_prompt`, `:stdin_error`

  Note: a `bash` command that runs but exits nonzero is **not** an error — it returns a
  successful result `%{"output", "exit_code", "ok" => false}` so the model can read the
  output and decide (a no-match `grep` exiting 1 is normal). See ADR 0005.
  """
  @type kind ::
          :invalid_args
          | :unknown_tool
          | :outside_workspace
          | :protected_path
          | :not_found
          | :resource_missing
          | :no_match
          | :not_unique
          | :read_failed
          | :write_failed
          | :command_failed
          | :timeout
          | :permission_denied
          | :write_policy_denied
          | :bash_disabled
          | :detached
          | :backpressure
          | :iteration_cap
          | :tool_result_record_failed
          | :session_record_unavailable
          | :unsafe_state_path
          | :corrupt_log_line
          | :ephemeral_not_loggable
          | :log_encode_failed
          | :log_read_failed
          | :log_write_failed
          | :session_writer_active
          | :session_writer_stale
          | :session_writer_ambiguous
          | :session_writer_lost
          | :provider_http_error
          | :model_not_supported
          | :usage_limit_reached
          | :rate_limited
          | :network
          | :provider_refusal
          | :unsupported_transport
          | :unsupported_backend_capability
          | :context_overflow
          | :stream_idle_timeout
          | :dangling_tool_call
          | :not_authenticated
          | :insecure_auth_transport
          | :token_request_failed
          | :no_account_id
          | :invalid_response
          | :corrupt_auth
          | :auth_read_failed
          | :auth_write_failed
          | :device_auth_failed
          | :device_code_unsupported
          | :session_start_failed
          | :no_prompt
          | :stdin_error

  @doc """
  Build the standard structured error envelope (ADR 0005). `kind` should be a member of
  the documented `t:kind/0` vocabulary so callers can branch on it.
  """
  @spec error(kind() | atom(), String.t(), map()) :: map()
  def error(kind, message, details \\ %{}) do
    %{ok: false, error: %{kind: kind, message: message, details: details}}
  end

  @doc """
  Token-bound a model-facing string (ADR 0005). The integer form preserves the
  established prefix-byte budget plus an explicit truncation marker.

  Pass `{:total_bytes, max}` when the entire result must fit a byte budget,
  including its marker. Small total budgets use a shortened marker (or an empty
  string for zero). Both forms replace invalid UTF-8 and preserve graphemes.
  """
  @spec truncate(binary(), non_neg_integer() | {:total_bytes, non_neg_integer()}) :: binary()
  def truncate(text, budget \\ @default_max_output)

  def truncate(text, max)
      when is_binary(text) and is_integer(max) and max >= 0 do
    text = String.replace_invalid(text)

    if byte_size(text) <= max,
      do: text,
      else: take_utf8_prefix(text, max) <> truncation_marker(max, byte_size(text))
  end

  def truncate(text, {:total_bytes, max})
      when is_binary(text) and is_integer(max) and max >= 0 do
    text = String.replace_invalid(text)

    if byte_size(text) <= max do
      text
    else
      total = byte_size(text)
      short = "\n…[truncated]"

      cond do
        byte_size(truncation_marker(0, total)) <= max ->
          # Reserving the marker using max's digit width is conservative even
          # when the actual prefix budget has fewer digits.
          prefix_budget = Kernel.max(0, max - byte_size(truncation_marker(max, total)))
          take_utf8_prefix(text, prefix_budget) <> truncation_marker(prefix_budget, total)

        byte_size(short) <= max ->
          take_utf8_prefix(text, max - byte_size(short)) <> short

        max >= 3 ->
          "…"

        true ->
          String.duplicate(".", max)
      end
    end
  end

  defp truncation_marker(prefix_bytes, total),
    do: "\n…[truncated, showing up to #{prefix_bytes} of #{total} bytes]"

  defp take_utf8_prefix(text, max), do: do_take_utf8_prefix(text, max, [])

  defp do_take_utf8_prefix(_text, remaining, acc) when remaining <= 0,
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_take_utf8_prefix("", _remaining, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_take_utf8_prefix(text, remaining, acc) do
    case String.next_grapheme(text) do
      {grapheme, rest} when byte_size(grapheme) <= remaining ->
        do_take_utf8_prefix(rest, remaining - byte_size(grapheme), [grapheme | acc])

      {_grapheme, _rest} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      nil ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
