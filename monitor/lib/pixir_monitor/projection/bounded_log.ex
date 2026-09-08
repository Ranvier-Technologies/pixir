defmodule PixirMonitor.Projection.BoundedLog do
  @moduledoc """
  Presenter limitations and error vocabulary for `Pixir.Log.fold_bounded/2`.

  Log reading, canonical decoding, and byte selection belong to Pixir.Log. This
  module only adapts selection metadata and failures to Monitor's existing schema.
  """

  @doc "Schema-compatible limitations; count values refer only to selected evidence."
  @spec limitations(map()) :: {:ok, [String.t()]}
  def limitations(%{"partial" => true} = selection) do
    note = "parent_log_prefix_tail:bytes_omitted=#{selection["bytes_omitted"]};events_omitted=unknown;events_retained=#{selection["events_retained"]};bytes_read=#{selection["bytes_read"]}"
    {:ok, [note, "partial_counts_lower_bounds", "parent_log_missing_middle", "omitted_event_count_unverifiable"]}
  end

  def limitations(%{"incomplete_trailing_bytes" => bytes}) when bytes > 0,
    do: {:ok, ["parent_log_incomplete_trailing_append"]}

  def limitations(_), do: {:ok, []}

  @doc "Whether bounded selection omitted any canonical history, including a trailing append."
  @spec incomplete?(map() | nil) :: boolean()
  def incomplete?(selection) when is_map(selection),
    do: selection["partial"] == true or (selection["incomplete_trailing_bytes"] || 0) > 0

  def incomplete?(_), do: false

  @doc "Human-readable child sampling notes on existing limitation surfaces, never exact unread event totals."
  @spec child_limitations(String.t(), map() | nil) :: {:ok, [String.t()]}
  def child_limitations(id, selection) do
    if incomplete?(selection) do
      shape = if selection["partial"], do: "prefix + tail only; missing middle", else: "complete records only; incomplete trailing append"

      {:ok,
       [
         "child_log_partial",
         "Partial child Log #{id} — #{shape}; #{selection["bytes_read"]} bytes read within the per-Log read bound; #{selection["events_retained"]} events retained; total events unknown. Retained counts and paths are lower bounds, not complete totals.",
         "child_event_total_unknown"
       ]}
    else
      {:ok, []}
    end
  end

  @doc "Adapt structured Log failures to the existing Monitor error vocabulary."
  @spec error(map(), String.t()) :: {:error, map()}
  def error(%{error: %{kind: kind, details: details}}, id) do
    mapped = error_kind(kind, details)
    safe_details = %{run_id: id}

    safe_details =
      case {kind, details["component_index"]} do
        {:unsafe_state_path, 0} -> Map.put(safe_details, :component, ".pixir")
        {:unsafe_state_path, 1} -> Map.put(safe_details, :component, "sessions")
        _ -> safe_details
      end

    safe_details = if is_integer(details[:bytes]), do: Map.put(safe_details, :bytes, details[:bytes]), else: safe_details
    safe_details = if kind == :corrupt_log_line, do: Map.put(safe_details, :reason, "corrupt_log_line"), else: safe_details
    safe_details = if kind == :invalid_log_selection, do: Map.put(safe_details, :reason, "invalid_selected_sequence"), else: safe_details
    safe_details = if kind == :log_read_failed and Map.has_key?(details, :reason), do: Map.put(safe_details, :reason, details.reason), else: safe_details

    message =
      case mapped do
        "run_not_found" -> "Run was not found"
        "run_log_failed" -> "Session Log could not be folded"
        "run_event_limit" -> "Session Log cannot be safely selected within the configured event bound"
        _ -> "Session Log cannot be safely selected within the configured byte bound"
      end

    if kind == :corrupt_log_line do
      require Logger
      Logger.warning("Session Log could not be folded: corrupt_log_line path=#{details[:path]}")
    end

    {:error, %{kind: mapped, message: message, details: safe_details}}
  end

  defp error_kind(:log_not_found, _), do: "run_not_found"
  defp error_kind(:log_read_limit, _), do: "run_log_limit"
  defp error_kind(:log_event_limit, _), do: "run_event_limit"
  defp error_kind(:invalid_args, _), do: "invalid_run_id"

  defp error_kind(:unsafe_state_path, details) do
    case {details["reason"], details["component_index"]} do
      {"symlink_component", 2} -> "symlink_rejected"
      {"symlink_component", _} -> "state_tree_symlink_rejected"
      {"non_directory_component", _} -> "state_tree_invalid"
      {"unexpected_file_type", 2} -> "run_log_invalid"
      {"lstat_failed", 2} -> "run_log_failed"
      {"lstat_failed", _} -> "state_tree_unavailable"
      _ -> "path_escape_rejected"
    end
  end

  defp error_kind(_, _), do: "run_log_failed"
end
