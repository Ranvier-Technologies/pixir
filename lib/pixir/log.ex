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

  Public Log operations validate the Session id and `lstat` the Pixir-owned path below
  the trusted Workspace root before use. Existing and dangling symlinks are refused.
  The check is a deterministic preflight, not protection against a same-UID process
  replacing a component between check and use.
  """

  alias Pixir.{Event, Paths, SessionId, SessionLease}

  @type history :: [Event.t()]

  @doc "Absolute path to a Session's Log. Accepts `:workspace` (default: cwd)."
  @spec path(String.t(), keyword()) :: String.t()
  def path(session_id, opts \\ []),
    do: Paths.session_log(session_id, workspace(opts))

  @doc "Whether a Log file exists for this Session yet (compatibility boolean)."
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(session_id, opts \\ []) do
    case exists(session_id, opts) do
      {:ok, exists?} -> exists?
      {:error, _error} -> false
    end
  end

  @doc """
  Return structured Session Log existence.

  Unlike `exists?/2`, this preserves invalid-id and unsafe-state-path errors so public
  callers do not collapse confinement failures into a misleading `not_found` result.
  """
  @spec exists(String.t(), keyword()) :: {:ok, boolean()} | {:error, map()}
  def exists(session_id, opts \\ []) do
    workspace = workspace(opts)

    with :ok <- SessionId.validate(session_id),
         {:ok, status} <-
           Paths.inspect_state_path(workspace, path(session_id, opts), expected: :regular) do
      {:ok, status.state == :regular}
    end
  end

  @doc """
  Create a new Session Log from canonical Events in one atomic write (temp + rename).

  Unlike `append/2`, this refuses when the Log already exists and writes the full file at
  once. Used for fork child Log creation where partial NDJSON must not remain on failure.
  """
  @spec create_session(String.t(), [Event.t()], keyword()) ::
          {:ok, [Event.t()]} | {:error, map()}
  def create_session(session_id, events, opts \\ []) when is_list(events) do
    with :ok <- SessionId.validate(session_id) do
      do_create_session(session_id, events, opts)
    end
  end

  defp do_create_session(session_id, events, opts) do
    workspace = workspace(opts)
    file = path(session_id, opts)

    with {:ok, false} <- exists(session_id, opts),
         {:ok, _dir} <- Paths.ensure_state_dir(workspace, Paths.sessions_dir(workspace)),
         :ok <- SessionLease.authorize_append(session_id, opts),
         {:ok, body} <- encode_lines(events, opts),
         :ok <- atomic_create(file, body, workspace) do
      {:ok, events}
    else
      {:ok, true} ->
        {:error,
         %{
           ok: false,
           error: %{
             kind: :already_exists,
             message: "session log already exists",
             details: %{session_id: session_id, path: file}
           }
         }}

      {:error, _error} = error ->
        error
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
    with :ok <- SessionId.validate(event.session_id) do
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
          workspace = workspace(opts)
          file = path(event.session_id, opts)

          with {:ok, _dir} <- Paths.ensure_state_dir(workspace, Paths.sessions_dir(workspace)),
               :ok <- SessionLease.authorize_append(event.session_id, opts),
               {:ok, line} <- encode_event(event, opts),
               :ok <- Paths.preflight_state_path(workspace, file, expected: :regular) do
            case File.write(file, line, [:append]) do
              :ok ->
                {:ok, event}

              {:error, posix} ->
                {:error,
                 %{
                   ok: false,
                   error: %{
                     kind: :log_write_failed,
                     message: "could not append to session log",
                     details: %{reason: posix, path: file}
                   }
                 }}
            end
          end
      end
    end
  end

  def append(_event, _opts) do
    {:error,
     %{
       ok: false,
       error: %{
         kind: :invalid_args,
         message: "log append requires an Event with a Session id",
         details: %{}
       }
     }}
  end

  @doc """
  Fold the Log into **History** — the ordered list of canonical Events. A missing Log
  is an empty History. Returns `{:ok, history}` or a structured error if a line is
  unparseable.
  """
  @spec fold(String.t(), keyword()) :: {:ok, history()} | {:error, map()}
  def fold(session_id, opts \\ []), do: read_and_decode(session_id, opts, :seq_order)

  @doc """
  Fold the Log in physical append order.

  This is a narrow evidence accessor for checks whose trust boundary must not depend on
  caller-authored `seq` values. Normal History consumers should keep using `fold/2`,
  which preserves the canonical seq-ordered replay contract.
  """
  @spec fold_append_order(String.t(), keyword()) :: {:ok, history()} | {:error, map()}
  def fold_append_order(session_id, opts \\ []),
    do: read_and_decode(session_id, opts, :append_order)

  defp read_and_decode(session_id, opts, order) do
    with :ok <- SessionId.validate(session_id) do
      do_read_and_decode(session_id, opts, order)
    end
  end

  defp do_read_and_decode(session_id, opts, order) do
    workspace = workspace(opts)
    file = path(session_id, opts)

    with {:ok, status} <- Paths.inspect_state_path(workspace, file, expected: :regular) do
      case status.state do
        :missing ->
          {:ok, []}

        :regular ->
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
              decode_all(contents, file, order)
          end
      end
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

  defp atomic_create(file, body, workspace) do
    tmp = file <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    with :ok <- Paths.preflight_new_state_path(workspace, tmp),
         :ok <- File.write(tmp, body),
         :ok <- Paths.preflight_state_path(workspace, tmp, expected: :regular),
         :ok <- Paths.preflight_new_state_path(workspace, file),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, %{error: _} = error} ->
        safe_remove_temp(tmp, workspace)
        {:error, error}

      {:error, reason} ->
        safe_remove_temp(tmp, workspace)

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

  defp safe_remove_temp(tmp, workspace) do
    case Paths.inspect_state_path(workspace, tmp, expected: :regular) do
      {:ok, %{state: :regular}} -> File.rm(tmp)
      _other -> :ok
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

  defp decode_all(contents, file, order) do
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
