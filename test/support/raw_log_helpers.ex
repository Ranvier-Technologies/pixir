defmodule Pixir.Test.RawLogHelpers do
  @moduledoc false

  alias Pixir.Log

  def write_raw_log(ws, sid, events) do
    path = Log.path(sid, workspace: ws)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
    sid
  end

  def raw_event(sid, seq, type, data) do
    %{
      "id" => "#{sid}-#{seq}",
      "session_id" => sid,
      "seq" => seq,
      "ts" => timestamp(seq),
      "type" => type,
      "data" => data
    }
  end

  defp timestamp(seq) do
    ~U[2026-06-30 00:00:00Z]
    |> DateTime.add(seq, :second)
    |> DateTime.to_iso8601()
  end
end
