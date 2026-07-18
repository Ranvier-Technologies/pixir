defmodule Pixir.Provider.OutputTruncationSummary do
  @moduledoc """
  Pure bounded projections of canonical Provider-output truncation evidence.

  This module is shared by diagnostics and replay inspection so historical and
  malformed evidence receives the same tri-state interpretation. It never rewrites
  History and keeps only the most recent 64 positive references.
  """

  alias Pixir.Provider.OutputTruncation

  @positive_ref_limit 64
  @child_warning_limit 64
  @id_re ~r/\A[A-Za-z0-9_.:-]+\z/
  @positive_reasons ~w(provider_content_filter provider_context_window_limit provider_output_limit)

  @doc "Summarize successful `provider_usage` calls in the supplied History scope."
  @spec summarize([map()]) :: map()
  def summarize(history) when is_list(history) do
    usages =
      history
      |> Enum.filter(&provider_usage?/1)
      |> Enum.sort_by(&event_order/1)

    projected = Enum.map(usages, &project/1)
    counts = Enum.frequencies_by(projected, & &1["status"])
    positives = Enum.filter(projected, &(&1["status"] == "truncated"))
    refs = positives |> Enum.take(-@positive_ref_limit) |> Enum.map(&positive_ref/1)

    %{
      "counts" => %{
        "not_truncated" => Map.get(counts, "not_truncated", 0),
        "truncated" => Map.get(counts, "truncated", 0),
        "unknown" => Map.get(counts, "unknown", 0)
      },
      "latest" => List.last(projected),
      "positive_count" => length(positives),
      "positive_refs" => refs,
      "positive_refs_truncated" => length(positives) > length(refs)
    }
  end

  @doc "Project one canonical usage Event with validated correlation fields."
  @spec project(map()) :: map()
  def project(%{id: id, seq: seq, data: data}) when is_map(data) do
    nested = Map.get(data, "output_truncation", Map.get(data, :output_truncation, :missing))

    {evidence, role} =
      case nested do
        :missing ->
          {OutputTruncation.from_event_data(data), nil}

        nested when is_map(nested) ->
          if valid_correlation?(nested, id) do
            evidence = OutputTruncation.from_event_data(data)

            role =
              if OutputTruncation.reason(evidence) == :invalid_evidence do
                nil
              else
                valid_role(Map.get(nested, "call_role", Map.get(nested, :call_role)))
              end

            {evidence, role}
          else
            {OutputTruncation.unknown(:invalid_evidence), nil}
          end

        _other ->
          {OutputTruncation.unknown(:invalid_evidence), nil}
      end

    evidence
    |> OutputTruncation.to_event_data()
    |> maybe_put("provider_usage_event_id", valid_id(id))
    |> maybe_put("provider_usage_seq", valid_seq(seq))
    |> maybe_put("call_role", role)
  end

  def project(%{"id" => id, "seq" => seq, "data" => data}) when is_map(data) do
    project(%{id: id, seq: seq, data: data})
  end

  def project(_event) do
    OutputTruncation.unknown(:historical_evidence_absent)
    |> OutputTruncation.to_event_data()
  end

  @doc "Build one bounded machine warning from valid positive canonical evidence."
  @spec warning(map()) :: map() | nil
  def warning(event) do
    projected = project(event)

    if projected["status"] == "truncated" and is_binary(projected["provider_usage_event_id"]) and
         is_integer(projected["provider_usage_seq"]) and
         projected["call_role"] in ["final_answer", "intermediate"] do
      %{
        "kind" => "provider_output_truncated",
        "severity" => "warning",
        "provider_usage_event_id" => projected["provider_usage_event_id"],
        "provider_usage_seq" => projected["provider_usage_seq"],
        "reason" => projected["reason"],
        "provider_reason" => projected["provider_reason"],
        "call_role" => projected["call_role"]
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  @doc "Validate positive assistant metadata used only as presentation fallback."
  @spec assistant_fallback(map()) :: {:ok, map(), map()} | :error
  def assistant_fallback(%{session_id: session_id, type: :assistant_message, data: data})
      when is_binary(session_id) and is_map(data) do
    with metadata when is_map(metadata) <- Map.get(data, "metadata", Map.get(data, :metadata)),
         false <- partial_metadata?(metadata),
         nested when is_map(nested) <-
           Map.get(metadata, "output_truncation", Map.get(metadata, :output_truncation)),
         {:ok, projection} <- correlated_projection(nested),
         "final_answer" <- projection["call_role"],
         true <- projection["status"] == "truncated" do
      warning =
        %{
          "kind" => "provider_output_truncated",
          "severity" => "warning",
          "provider_usage_event_id" => projection["provider_usage_event_id"],
          "provider_usage_seq" => projection["provider_usage_seq"],
          "reason" => projection["reason"],
          "provider_reason" => projection["provider_reason"],
          "call_role" => "final_answer"
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, projection, warning}
    else
      _ -> :error
    end
  end

  def assistant_fallback(_event), do: :error

  @doc "Normalize a Presenter correlation object without accepting malformed keys."
  @spec correlated_projection(map()) :: {:ok, map()} | :error
  def correlated_projection(nested) when is_map(nested) do
    with false <- duplicate_correlation_keys?(nested),
         event_id when is_binary(event_id) <-
           Map.get(
             nested,
             "provider_usage_event_id",
             Map.get(nested, :provider_usage_event_id)
           ),
         true <- valid_id(event_id) == event_id,
         seq when is_integer(seq) and seq >= 0 <-
           Map.get(nested, "provider_usage_seq", Map.get(nested, :provider_usage_seq)),
         role when role in ["final_answer", "intermediate"] <-
           Map.get(nested, "call_role", Map.get(nested, :call_role)),
         evidence <- OutputTruncation.normalize(nested),
         false <- OutputTruncation.reason(evidence) == :invalid_evidence do
      {:ok,
       evidence
       |> OutputTruncation.to_event_data()
       |> Map.put("provider_usage_event_id", event_id)
       |> Map.put("provider_usage_seq", seq)
       |> Map.put("call_role", role)}
    else
      _ -> :error
    end
  end

  def correlated_projection(_nested), do: :error

  @doc "Normalize bounded child-output warning aggregates at a Presenter boundary."
  @spec normalize_child_output(map()) :: map()
  def normalize_child_output(data) when is_map(data) do
    fallback_sid = valid_id(Map.get(data, "child_session_id", Map.get(data, :child_session_id)))

    all_warnings =
      data
      |> Map.get("output_warnings", Map.get(data, :output_warnings, []))
      |> normalize_warning_list(fallback_sid)

    retained = Enum.take(all_warnings, @child_warning_limit)
    raw_count = Map.get(data, "output_warning_count", Map.get(data, :output_warning_count))

    count =
      cond do
        all_warnings == [] ->
          0

        Map.get(data, "output_warnings_truncated", Map.get(data, :output_warnings_truncated)) ==
          true and is_integer(raw_count) and raw_count >= length(all_warnings) ->
          raw_count

        true ->
          length(all_warnings)
      end

    final_projection = normalize_final_projection(data)

    reasons =
      if count > 0 do
        explicit_reasons =
          data
          |> Map.get("output_warning_reasons", Map.get(data, :output_warning_reasons, []))
          |> bounded_warning_prefix(16)
          |> Enum.filter(&(&1 in @positive_reasons))

        all_warnings
        |> Enum.map(& &1["reason"])
        |> Kernel.++(explicit_reasons)
        |> Enum.uniq()
        |> Enum.sort()
      else
        []
      end

    latest_order_key =
      all_warnings
      |> Enum.map(&warning_order_key/1)
      |> maybe_add_final_order_key(final_projection)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    %{
      "output_truncation" => final_projection,
      "output_warning_count" => count,
      "output_warnings" => retained,
      "output_warning_reasons" => reasons,
      "output_warnings_truncated" => count > length(retained),
      "output_latest_warning_order_key" => latest_order_key
    }
  end

  def normalize_child_output(_data) do
    %{
      "output_truncation" => nil,
      "output_warning_count" => 0,
      "output_warnings" => [],
      "output_warning_reasons" => [],
      "output_warnings_truncated" => false,
      "output_latest_warning_order_key" => nil
    }
  end

  @doc "Return the bounded model-context warning suffix for a terminal child summary."
  @spec child_context_suffix(map()) :: String.t()
  def child_context_suffix(data) when is_map(data) do
    normalized = normalize_child_output(data)
    count = normalized["output_warning_count"]

    if is_integer(count) and count > 0 do
      reasons = normalized["output_warning_reasons"]
      count_text = if count > 999_999, do: "999999+", else: Integer.to_string(count)

      "\n\n[Pixir output warning: child provider output was truncated; " <>
        "call_count=#{count_text}; reasons=#{Enum.join(reasons, ",")}]"
    else
      ""
    end
  end

  def child_context_suffix(_data), do: ""

  defp positive_ref(projected) do
    Map.take(projected, [
      "provider_usage_event_id",
      "provider_usage_seq",
      "reason",
      "provider_reason",
      "call_role"
    ])
  end

  defp provider_usage?(%{type: :provider_usage}), do: true
  defp provider_usage?(%{"type" => "provider_usage"}), do: true
  defp provider_usage?(_event), do: false

  defp event_order(%{seq: seq, id: id}), do: {order_seq(seq), order_id(id)}
  defp event_order(%{"seq" => seq, "id" => id}), do: {order_seq(seq), order_id(id)}
  defp event_order(_event), do: {9_223_372_036_854_775_807, ""}

  defp order_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp order_seq(_seq), do: 9_223_372_036_854_775_807
  defp order_id(id) when is_binary(id), do: id
  defp order_id(_id), do: ""

  defp valid_correlation?(nested, outer_id) when is_map(nested) do
    inner_id =
      Map.get(nested, "provider_usage_event_id", Map.get(nested, :provider_usage_event_id))

    inner_role = Map.get(nested, "call_role", Map.get(nested, :call_role))

    duplicate_id? =
      Map.has_key?(nested, "provider_usage_event_id") and
        Map.has_key?(nested, :provider_usage_event_id)

    duplicate_role? = Map.has_key?(nested, "call_role") and Map.has_key?(nested, :call_role)

    not duplicate_id? and not duplicate_role? and valid_id(outer_id) == outer_id and
      inner_id == outer_id and valid_role(inner_role) == inner_role
  end

  defp duplicate_correlation_keys?(nested) do
    Enum.any?([:provider_usage_event_id, :provider_usage_seq, :call_role], fn key ->
      Map.has_key?(nested, key) and Map.has_key?(nested, Atom.to_string(key))
    end)
  end

  defp valid_id(id) when is_binary(id) and byte_size(id) in 1..160 do
    if String.valid?(id) and Regex.match?(@id_re, id), do: id
  end

  defp valid_id(_id), do: nil
  defp valid_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp valid_seq(_seq), do: nil
  defp valid_role(role) when role in ["final_answer", "intermediate"], do: role
  defp valid_role(_role), do: nil

  defp partial_metadata?(metadata) do
    Map.get(metadata, "partial") == true or Map.get(metadata, :partial) == true
  end

  defp normalize_warning_list(warnings, fallback_sid) do
    warnings
    |> bounded_warning_prefix(@child_warning_limit)
    |> Enum.map(&normalize_child_warning(&1, fallback_sid))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&{&1["child_session_id"], &1["provider_usage_event_id"]})
    |> Enum.sort_by(&warning_order_key/1)
  end

  defp bounded_warning_prefix(_warnings, 0), do: []
  defp bounded_warning_prefix([], _remaining), do: []

  defp bounded_warning_prefix([warning | rest], remaining),
    do: [warning | bounded_warning_prefix(rest, remaining - 1)]

  defp bounded_warning_prefix(_malformed_tail, _remaining), do: []

  defp normalize_child_warning(warning, fallback_sid) when is_map(warning) do
    raw_child_sid =
      cond do
        Map.has_key?(warning, "child_session_id") -> warning["child_session_id"]
        Map.has_key?(warning, :child_session_id) -> warning[:child_session_id]
        true -> :missing
      end

    child_sid =
      case raw_child_sid do
        :missing -> fallback_sid
        sid -> if valid_id(sid) == fallback_sid, do: fallback_sid
      end

    event_id =
      valid_id(
        Map.get(
          warning,
          "provider_usage_event_id",
          Map.get(warning, :provider_usage_event_id)
        )
      )

    seq = Map.get(warning, "provider_usage_seq", Map.get(warning, :provider_usage_seq))
    role = Map.get(warning, "call_role", Map.get(warning, :call_role))
    reason = Map.get(warning, "reason", Map.get(warning, :reason))
    provider_reason = Map.get(warning, "provider_reason", Map.get(warning, :provider_reason))

    evidence =
      OutputTruncation.normalize(%{
        status: :truncated,
        reason: reason,
        provider_reason: provider_reason
      })

    if is_binary(child_sid) and is_binary(event_id) and is_integer(seq) and seq >= 0 and
         role in ["final_answer", "intermediate"] and reason in @positive_reasons and
         OutputTruncation.status(evidence) == :truncated do
      %{
        "kind" => "provider_output_truncated",
        "severity" => "warning",
        "child_session_id" => child_sid,
        "provider_usage_event_id" => event_id,
        "provider_usage_seq" => seq,
        "call_role" => role,
        "reason" => reason,
        "provider_reason" => OutputTruncation.provider_reason(evidence)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    end
  end

  defp normalize_child_warning(_warning, _fallback_sid), do: nil

  defp normalize_final_projection(data) do
    nested = Map.get(data, "output_truncation", Map.get(data, :output_truncation))

    case correlated_projection(nested) do
      {:ok, %{"call_role" => "final_answer"} = projection} -> projection
      _ -> nil
    end
  end

  defp warning_order_key(warning) do
    {warning["provider_usage_seq"], warning["provider_usage_event_id"]}
  end

  defp maybe_add_final_order_key(keys, %{
         "status" => "truncated",
         "provider_usage_seq" => seq,
         "provider_usage_event_id" => id
       }),
       do: [{seq, id} | keys]

  defp maybe_add_final_order_key(keys, _projection), do: keys

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
