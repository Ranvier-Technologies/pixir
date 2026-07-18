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

    File.write!(path, body)
    session_id
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
