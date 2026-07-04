defmodule Pixir.Delegate.Progress do
  @moduledoc """
  Shared progress-frame contract for Delegate attach observation.

  `pixir delegate attach --progress=stderr-jsonl` has two producers: the ordinary
  snapshot path and the daemon-backed follow path. This module keeps their JSONL frame
  shape aligned so orchestrators can consume one stable contract while Pixir preserves
  the Log as the source of truth.
  """

  @contract_version 1
  @terminal_statuses ~w(completed partial failed timed_out cancelled)

  @doc "Build a Delegate progress, terminal, or heartbeat frame from a payload."
  @spec frame(map(), pos_integer(), keyword()) :: map()
  def frame(payload, sequence, opts \\ [])
      when is_map(payload) and is_integer(sequence) and sequence > 0 do
    source = Keyword.get(opts, :source) || source(payload, opts)
    terminal? = terminal?(payload)
    type = Keyword.get(opts, :type) || frame_type(terminal?)

    %{
      "type" => type,
      "kind" => "delegate_attach_progress",
      "sequence" => sequence,
      "contract_version" => @contract_version,
      "delegate_id" => payload["delegate_id"],
      "parent_session_id" => payload["parent_session_id"] || payload["session_id"],
      "status" => payload["status"],
      "complete" => payload["complete"] == true,
      "terminal" => type == "delegate_terminal" or terminal?,
      "service_state" => payload["service_state"],
      "counts" => Map.get(payload, "counts", %{}),
      "attach" => attach_summary(payload),
      "owner" => owner_summary(payload),
      "runtime_residency" =>
        Map.get(payload, "runtime_residency") || get_in(payload, ["owner", "runtime_residency"]),
      "host_boundary" => Map.get(payload, "host_boundary", %{}),
      "source" => source,
      "owner_backed" => owner_backed_source?(source),
      "daemon_fallback" => Map.get(payload, "daemon_fallback"),
      "observed_at" => now()
    }
    |> maybe_put("heartbeat", Keyword.get(opts, :heartbeat?))
  end

  @doc "Build a recoverable progress error frame."
  @spec error_frame(map(), pos_integer(), map(), keyword()) :: map()
  def error_frame(error, sequence, handle, opts \\ [])
      when is_map(error) and is_integer(sequence) and sequence > 0 and is_map(handle) do
    %{
      "type" => "delegate_progress_error",
      "kind" => error["kind"] || "delegate_progress_error",
      "sequence" => sequence,
      "contract_version" => @contract_version,
      "delegate_id" => handle["delegate_id"],
      "parent_session_id" => handle["parent_session_id"],
      "status" => "partial",
      "complete" => false,
      "terminal" => false,
      "source" => Keyword.get(opts, :source, "durable_snapshot_after_daemon_fallback"),
      "service_state" => Keyword.get(opts, :service_state, "owner_unavailable"),
      "message" => error["message"] || "delegate progress follow failed",
      "details" => Map.get(error, "details", %{}),
      "observed_at" => now()
    }
  end

  @doc "Attach progress metadata to the final Delegate payload."
  @spec annotate(map(), map()) :: map()
  def annotate(payload, progress) when is_map(payload) and is_map(progress) do
    progress =
      progress
      |> Map.put_new("requested", true)
      |> Map.put_new("mode", "stderr-jsonl")
      |> Map.put_new(
        "source",
        source(payload, streaming?: progress["follow_transport"] == "daemon_stream")
      )

    progress =
      progress
      |> Map.put_new("owner_backed", owner_backed_source?(progress["source"]))
      |> Map.put_new("terminal_observed", terminal?(payload))
      |> Map.put_new("stdout_contract", "one_final_json_envelope")

    payload
    |> Map.put("command_ok", true)
    |> Map.put("work_complete", work_complete?(payload))
    |> Map.put("exit_code", Map.get(progress, "exit_code"))
    |> update_in(["attach"], fn
      %{} = attach -> Map.put(attach, "progress", progress)
      _other -> %{"progress" => progress}
    end)
    |> Map.put("progress", progress)
  end

  @doc "Whether a payload is terminal for attach observation."
  @spec terminal?(map()) :: boolean()
  def terminal?(%{"status" => status}) when status in @terminal_statuses, do: true
  def terminal?(%{"complete" => true}), do: true
  def terminal?(_payload), do: false

  @doc "Source vocabulary for a payload observation."
  @spec source(map(), keyword()) :: String.t()
  def source(payload, opts \\ []) do
    cond do
      Keyword.get(opts, :source) ->
        Keyword.fetch!(opts, :source)

      Map.has_key?(payload, "daemon_fallback") ->
        "durable_snapshot_after_daemon_fallback"

      live_owner?(payload) and Keyword.get(opts, :streaming?, false) ->
        "live_owner_stream"

      live_owner?(payload) ->
        "live_owner_snapshot"

      true ->
        "durable_snapshot"
    end
  end

  @doc "Whether a source comes from a live owner."
  @spec owner_backed_source?(String.t() | nil) :: boolean()
  def owner_backed_source?(source), do: source in ["live_owner_stream", "live_owner_snapshot"]

  defp frame_type(true), do: "delegate_terminal"
  defp frame_type(false), do: "delegate_progress"

  defp attach_summary(payload) do
    Map.take(Map.get(payload, "attach", %{}), [
      "mode",
      "streaming",
      "source",
      "status",
      "complete",
      "service_state"
    ])
  end

  defp owner_summary(payload) do
    Map.take(Map.get(payload, "owner", %{}), [
      "state",
      "reachable",
      "delegate_owner",
      "runtime_residency"
    ])
  end

  defp live_owner?(payload) do
    get_in(payload, ["owner", "state"]) == "live_delegate_owner" and
      get_in(payload, ["owner", "reachable"]) != false
  end

  defp work_complete?(%{"status" => "completed", "complete" => true}), do: true
  defp work_complete?(_payload), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
