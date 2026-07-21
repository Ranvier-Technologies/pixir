defmodule PixirMonitor.FixtureWorkspace do
  @moduledoc false

  @spec materialize!(map(), Path.t()) :: String.t()
  def materialize!(
        %{
          "inputs" => %{
            "terminal_envelope" => %{"parent_session_id" => session_id},
            "parent_log" => events
          }
        },
        target_directory
      )
      when is_binary(session_id) and is_list(events) and is_binary(target_directory) do
    :ok = ensure_safe_session_id!(session_id)
    sessions_directory = Path.join([target_directory, ".pixir", "sessions"])
    File.mkdir_p!(sessions_directory)
    path = Path.join(sessions_directory, "#{session_id}.ndjson")

    if File.exists?(path) do
      raise ArgumentError,
            "refusing to overwrite existing append-only Session Log: #{session_id}.ndjson"
    end

    body =
      Enum.map_join(events, "", fn event ->
        event
        |> wrapped_event(session_id)
        |> Jason.encode!()
        |> Kernel.<>("\n")
      end)

    write_atomic!(path, body)
    session_id
  end

  # The session id becomes a filename under the sessions directory, so it must be
  # a single safe path component. Validate against the canonical Session id
  # grammar (mirrored from Pixir.SessionId: leading letter/number/underscore,
  # then letters/numbers/marks/_.-). This rejects path separators, parent
  # references, absolute paths, NUL bytes, and Unicode separator lookalikes in
  # one check, so a malformed envelope cannot materialize a Log outside the
  # fixture sandbox.
  @session_id_grammar ~r/\A[\p{L}\p{N}_][\p{L}\p{N}\p{M}_.-]*\z/u

  defp ensure_safe_session_id!(session_id) do
    unless Regex.match?(@session_id_grammar, session_id) do
      raise ArgumentError,
            "refusing to materialize a Session Log for an unsafe session id: #{inspect(session_id)}"
    end

    :ok
  end

  # Write via a temporary sibling and rename so a crash mid-write can never
  # leave a partially materialized append-only Log for another test to read.
  defp write_atomic!(path, body) do
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    try do
      File.write!(tmp, body)
      File.rename!(tmp, path)
    rescue
      error ->
        File.rm(tmp)
        reraise(error, __STACKTRACE__)
    end
  end

  defp wrapped_event(event, session_id) do
    seq = Map.fetch!(event, "seq")

    %{
      "id" => "event-#{session_id}-#{seq}",
      "session_id" => session_id,
      "seq" => seq,
      "ts" => Map.fetch!(event, "ts"),
      "type" => Map.fetch!(event, "type"),
      "data" => Map.fetch!(event, "data")
    }
  end
end
