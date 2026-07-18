defmodule Pixir.ReplayInspector do
  @moduledoc """
  Read-only replay inspection for local Pixir Logs.

  This module reconstructs the Provider input that Pixir would build from a Session
  History without calling auth, the network, or the model. It is an operator diagnostic
  seam for replay/projection incidents: count function calls, paired outputs, and
  synthetic orphan closures from canonical Log events. It also summarizes
  audit-only evidence that must not be replayed as clean Provider context.
  """

  alias Pixir.{Log, Provider, Tool}
  alias Pixir.Provider.OutputTruncationSummary

  @type inspect_opts :: [
          workspace: String.t(),
          after_seq: non_neg_integer() | nil,
          model: term(),
          config_path: String.t(),
          raw_config: map(),
          request_snapshot_loader: (keyword() -> term())
        ]

  @doc """
  Inspect Provider replay input for `session_id`.

  `:after_seq` means "the replay state after this Event seq", so only Events with
  `seq <= after_seq` are included. When omitted, the full Log is inspected.
  """
  @spec inspect(String.t(), inspect_opts()) :: {:ok, map()} | {:error, map()}
  def inspect(session_id, opts \\ [])

  def inspect(session_id, opts) when is_binary(session_id) do
    workspace = Keyword.get(opts, :workspace, File.cwd!())

    case Log.exists(session_id, workspace: workspace) do
      {:ok, true} ->
        with {:ok, history} <- Log.fold(session_id, workspace: workspace),
             {:ok, after_seq} <- validate_after_seq(Keyword.get(opts, :after_seq)),
             scoped_history <- scope_history(history, after_seq),
             {:ok, body} <- provider_body(session_id, scoped_history, opts, workspace) do
          {:ok, report(session_id, workspace, history, scoped_history, body, after_seq)}
        end

      {:ok, false} ->
        {:error,
         Tool.error(:not_found, "session log not found", %{
           session_id: session_id,
           path: Log.path(session_id, workspace: workspace)
         })}

      {:error, _error} = error ->
        error
    end
  end

  def inspect(_session_id, _opts) do
    {:error, Tool.error(:invalid_args, "inspect/2 requires a string session id")}
  end

  defp validate_after_seq(nil), do: {:ok, nil}
  defp validate_after_seq(seq) when is_integer(seq) and seq >= 0, do: {:ok, seq}

  defp validate_after_seq(_seq),
    do: {:error, Tool.error(:invalid_args, "--after-seq must be a non-negative integer")}

  defp scope_history(history, nil), do: history
  defp scope_history(history, after_seq), do: Enum.filter(history, &event_seq_lte?(&1, after_seq))

  defp event_seq_lte?(%{seq: seq}, after_seq) when is_integer(seq), do: seq <= after_seq
  defp event_seq_lte?(_event, _after_seq), do: true

  defp provider_body(session_id, history, opts, workspace) do
    request = %{
      workspace: workspace,
      history: history,
      system_prompt: "Replay inspection only.",
      developer_context: "Replay inspection for session #{session_id} in #{workspace}."
    }

    request =
      case Keyword.fetch(opts, :model) do
        :error -> request
        {:ok, nil} -> request
        {:ok, model} -> Map.put(request, :model, model)
      end

    Provider.request_body_preview(
      request,
      Keyword.take(opts, [:config_path, :raw_config, :request_snapshot_loader])
    )
  end

  defp report(session_id, workspace, full_history, scoped_history, body, after_seq) do
    input = Map.get(body, "input", [])
    function_calls = Enum.filter(input, &(Map.get(&1, "type") == "function_call"))
    function_outputs = Enum.filter(input, &(Map.get(&1, "type") == "function_call_output"))
    assistant_messages = Enum.filter(input, &assistant_message_input?/1)
    synthetic_orphans = Enum.filter(function_outputs, &synthetic_orphan_output?/1)

    call_ids = ids(function_calls)
    output_ids = ids(function_outputs)
    missing_output_ids = call_ids -- output_ids
    extra_output_ids = output_ids -- call_ids

    %{
      "ok" => true,
      "session_id" => session_id,
      "workspace" => workspace,
      "after_seq" => after_seq,
      "events" => event_summary(full_history, scoped_history),
      "provider_input" => %{
        "items" => length(input),
        "assistant_messages" => length(assistant_messages),
        "function_calls" => length(function_calls),
        "function_call_outputs" => length(function_outputs),
        "missing_output_ids" => missing_output_ids,
        "extra_output_ids" => extra_output_ids,
        "synthetic_orphan_closures" => Enum.map(synthetic_orphans, &orphan_summary/1),
        "balanced" => missing_output_ids == [] and extra_output_ids == []
      },
      "replay_contract" => replay_contract_summary(scoped_history, assistant_messages),
      "output_truncation" => OutputTruncationSummary.summarize(scoped_history),
      "continuation" => continuation_summary(scoped_history)
    }
  end

  defp ids(items), do: items |> Enum.map(&Map.get(&1, "call_id")) |> Enum.reject(&is_nil/1)

  defp event_summary(full_history, scoped_history) do
    seqs = scoped_history |> Enum.map(& &1.seq) |> Enum.filter(&is_integer/1)

    %{
      "full_count" => length(full_history),
      "inspected_count" => length(scoped_history),
      "from_seq" => Enum.min(seqs, fn -> nil end),
      "to_seq" => Enum.max(seqs, fn -> nil end),
      "assistant_messages" => count_type(scoped_history, :assistant_message),
      "partial_assistant_messages" => count_partial_assistant(scoped_history),
      "turn_failed" => count_type(scoped_history, :turn_failed),
      "provider_usage" => count_type(scoped_history, :provider_usage),
      "tool_calls" => count_type(scoped_history, :tool_call),
      "tool_results" => count_type(scoped_history, :tool_result)
    }
  end

  defp count_type(history, type), do: Enum.count(history, &(&1.type == type))

  defp count_partial_assistant(history) do
    Enum.count(history, &partial_assistant?/1)
  end

  defp partial_assistant?(%{type: :assistant_message, data: %{"metadata" => metadata}})
       when is_map(metadata) do
    metadata["partial"] == true
  end

  defp partial_assistant?(_event), do: false

  defp assistant_message_input?(%{"type" => "message", "role" => "assistant"}), do: true
  defp assistant_message_input?(_item), do: false

  defp replay_contract_summary(history, assistant_messages) do
    partial_assistant_count = count_partial_assistant(history)
    turn_failed_count = count_type(history, :turn_failed)
    provider_usage_count = count_type(history, :provider_usage)

    %{
      "clean_assistant_messages_replayed" => length(assistant_messages),
      "partial_assistant_messages_excluded" => partial_assistant_count,
      "turn_failed_events_excluded" => turn_failed_count,
      "provider_usage_events_excluded" => provider_usage_count,
      "audit_only_events_excluded" =>
        partial_assistant_count + turn_failed_count + provider_usage_count
    }
  end

  defp synthetic_orphan_output?(%{"output" => output}) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, %{"error" => %{"kind" => "orphan_tool_call"}}} -> true
      _ -> false
    end
  end

  defp synthetic_orphan_output?(_item), do: false

  defp orphan_summary(%{"call_id" => call_id, "output" => output}) do
    decoded =
      case Jason.decode(output) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    details = get_in(decoded, ["error", "details"]) || %{}

    %{
      "call_id" => call_id,
      "tool" => details["tool"],
      "kind" => get_in(decoded, ["error", "kind"])
    }
  end

  defp continuation_summary(history) do
    history
    |> Enum.filter(&(&1.type == :provider_usage))
    |> List.last()
    |> case do
      nil ->
        %{"present" => false}

      %{seq: seq, data: data} ->
        %{
          "present" => true,
          "seq" => seq,
          "active_transport" => data["active_transport"],
          "continuation_attempted" => data["continuation_attempted"],
          "continuation_reset_reason" => data["continuation_reset_reason"],
          "used_previous_response_id" => data["used_previous_response_id"],
          "websocket_captured_response_id" => data["websocket_captured_response_id"],
          "websocket_stored_previous_response_id" => data["websocket_stored_previous_response_id"]
        }
    end
  end
end
