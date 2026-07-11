defmodule Pixir.Log do
  @moduledoc """
  The per-Session **Log** (ADR 0003 / 0004): an append-only NDJSON file at
  `.pixir/sessions/<id>.ndjson`, the single source of truth for a Session.

  Only **canonical** Events are written — one `Pixir.Event` per line, serialized 1:1.
  `fold/2` replays the file into **History**: the ordered list of canonical Events
  (by `seq`, with file append order as the backstop, per ADR 0004).

  Append is the deliberate exception to the temp+rename rule (the file only ever grows
  and a single Session process serializes writes). When a Session writer lease exists,
  appends must present the matching holder; raw append remains available only for cold
  fixture/import paths where no writer lease is active. Ephemeral Events are never logged.
  """

  alias Pixir.{Event, Paths, SessionLease}

  @type history :: [Event.t()]

  @doc "Absolute path to a Session's Log. Accepts `:workspace` (default: cwd)."
  @spec path(String.t(), keyword()) :: String.t()
  def path(session_id, opts \\ []),
    do: Paths.session_log(session_id, workspace(opts))

  @doc "Whether a Log file exists for this Session yet."
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(session_id, opts \\ []), do: File.exists?(path(session_id, opts))

  @doc """
  Create a new Session Log from canonical Events in one atomic write (temp + rename).

  Unlike `append/2`, this refuses when the Log already exists and writes the full file at
  once. Used for fork child Log creation where partial NDJSON must not remain on failure.
  """
  @spec create_session(String.t(), [Event.t()], keyword()) ::
          {:ok, [Event.t()]} | {:error, map()}
  def create_session(session_id, events, opts \\ []) when is_list(events) do
    if exists?(session_id, opts) do
      {:error,
       %{
         ok: false,
         error: %{
           kind: :already_exists,
           message: "session log already exists",
           details: %{session_id: session_id, path: path(session_id, opts)}
         }
       }}
    else
      file = path(session_id, opts)
      Paths.ensure_sessions_dir(workspace(opts))

      with :ok <- SessionLease.authorize_append(session_id, opts),
           {:ok, body} <- encode_lines(events, opts),
           :ok <- atomic_create(file, body) do
        {:ok, events}
      end
    end
  end

  @doc """
  Append a **canonical** Event to the Session's Log. Ephemeral Events are rejected
  with a structured error (ADR 0005) — logging one is a programming error.

  Returns `{:ok, event}` on success.
  """
  @spec append(Event.t(), keyword()) :: {:ok, Event.t()} | {:error, map()}
  def append(event, opts \\ [])

  def append(%{type: type} = event, opts) do
    cond do
      not Event.canonical?(event) ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :ephemeral_not_loggable,
             message: "refusing to persist a non-canonical event",
             details: %{type: type}
           }
         }}

      true ->
        Paths.ensure_sessions_dir(workspace(opts))

        with :ok <- SessionLease.authorize_append(event.session_id, opts),
             {:ok, line} <- encode_event(event, opts) do
          case File.write(path(event.session_id, opts), line, [:append]) do
            :ok ->
              {:ok, event}

            {:error, posix} ->
              {:error,
               %{
                 ok: false,
                 error: %{
                   kind: :log_write_failed,
                   message: "could not append to session log",
                   details: %{reason: posix, path: path(event.session_id, opts)}
                 }
               }}
          end
        end
    end
  end

  @doc """
  Fold the Log into **History** — the ordered list of canonical Events. A missing Log
  is an empty History. Returns `{:ok, history}` or a structured error if a line is
  unparseable.
  """
  @spec fold(String.t(), keyword()) :: {:ok, history()} | {:error, map()}
  def fold(session_id, opts \\ []) do
    file = path(session_id, opts)

    case File.read(file) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, posix} ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :log_read_failed,
             message: "could not read session log",
             details: %{reason: posix, path: file}
           }
         }}

      {:ok, contents} ->
        decode_all(contents, file)
    end
  end

  @doc """
  Fold the Log in physical append order.

  This is a narrow evidence accessor for checks whose trust boundary must not depend on
  caller-authored `seq` values. Normal History consumers should keep using `fold/2`,
  which preserves the canonical seq-ordered replay contract.
  """
  @spec fold_append_order(String.t(), keyword()) :: {:ok, history()} | {:error, map()}
  def fold_append_order(session_id, opts \\ []) do
    file = path(session_id, opts)

    case File.read(file) do
      {:error, :enoent} ->
        {:ok, []}

      {:error, posix} ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :log_read_failed,
             message: "could not read session log",
             details: %{reason: posix, path: file}
           }
         }}

      {:ok, contents} ->
        decode_all(contents, file, :append_order)
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp encode_lines(events, opts) do
    events
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, acc} ->
      case encode_event(event, opts) do
        {:ok, line} -> {:cont, {:ok, [line | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines) |> IO.iodata_to_binary()}
      {:error, _} = error -> error
    end
  end

  defp atomic_create(file, body) do
    tmp = file <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)

        {:error,
         %{
           ok: false,
           error: %{
             kind: :log_write_failed,
             message: "could not create session log",
             details: %{reason: reason, path: file}
           }
         }}
    end
  end

  defp encode_event(event, opts) do
    case Jason.encode(event) do
      {:ok, encoded} ->
        {:ok, encoded <> "\n"}

      {:error, exception} ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :log_encode_failed,
             message: "could not encode event for session log",
             details: %{
               reason: Exception.message(exception),
               type: event.type,
               session_id: event.session_id,
               path: path(event.session_id, opts)
             }
           }
         }}
    end
  rescue
    exception ->
      {:error,
       %{
         ok: false,
         error: %{
           kind: :log_encode_failed,
           message: "could not encode event for session log",
           details: %{
             reason: Exception.message(exception),
             type: event.type,
             session_id: event.session_id,
             path: path(event.session_id, opts)
           }
         }
       }}
  end

  defp decode_all(contents, file, order \\ :seq_order) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while([], fn line, acc ->
      case decode_line(line) do
        {:ok, event} -> {:cont, [event | acc]}
        {:error, reason} -> {:halt, {:error, line_error(reason, file)}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      events -> {:ok, order_decoded_events(Enum.reverse(events), order)}
    end
  end

  defp order_decoded_events(events, :append_order), do: events
  defp order_decoded_events(events, :seq_order), do: sort_history(events)

  defp decode_line(line) do
    with {:ok, map} when is_map(map) <- Jason.decode(line),
         {:ok, type} <- decode_type(map["type"]) do
      {:ok,
       %{
         id: map["id"],
         session_id: map["session_id"],
         seq: map["seq"],
         ts: map["ts"],
         type: type,
         data: map["data"] || %{}
       }}
    else
      {:error, %Jason.DecodeError{} = e} -> {:error, {:invalid_json, Exception.message(e)}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  # The declared canonical type set is the source of truth — never `to_existing_atom`,
  # whose success depends on whether the atom happens to already exist in the VM. On a
  # cold `resume` the writer side hasn't run, so the atom may be absent even though the
  # type is valid; that produced spurious `:unknown_event_type` crashes. Only canonical
  # events are ever written, so matching against the canonical set is exact.
  @canonical_type_strings Map.new(Pixir.Event.canonical_types(), &{Atom.to_string(&1), &1})

  defp decode_type(type) when is_binary(type) do
    case Map.fetch(@canonical_type_strings, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:unknown_event_type, type}}
    end
  end

  defp decode_type(other), do: {:error, {:missing_event_type, other}}

  # Primary order is `seq`; events lacking a seq fall back to file (append) order.
  defp sort_history(events) do
    Enum.sort_by(events, &{is_nil(&1.seq), &1.seq})
  end

  defp line_error(reason, file) do
    %{
      ok: false,
      error: %{
        kind: :corrupt_log_line,
        message: "could not decode a log line",
        details: %{reason: reason, path: file}
      }
    }
  end

  defp workspace(opts), do: Keyword.get(opts, :workspace) || File.cwd!()
end
