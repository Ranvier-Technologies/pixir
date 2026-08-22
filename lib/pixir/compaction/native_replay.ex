defmodule Pixir.Compaction.NativeReplay do
  @moduledoc """
  Store, validate, and inspect `history_compaction.data.native_replay` (ADR 0040).

  Slice C persists a live `/responses/compact` `output` as `standalone_window`.
  Slice D persists a live stream `cmp_` as `threshold_item` and shares the same
  overlay preference, late-bound after Provider/backend resolve. Overlay on
  `chatgpt_codex` enables D only; standalone C stays local on that 404 host.
  """

  alias Pixir.Tool

  @modes ["standalone_window", "threshold_item"]
  @fallback_reasons [
    "missing_compaction_item",
    "missing_encrypted_content",
    "standalone_window_pruned",
    "threshold_item_not_singleton",
    "unpaired_function_call",
    "malformed_native_replay",
    "guard_mismatch",
    "backend_rejected",
    "native_unavailable",
    "overlay_off",
    "http_404",
    "transport"
  ]

  @local_required ["range", "strategy", "summary", "limitations"]

  @doc "Accepted `native_replay.mode` values."
  @spec modes() :: [String.t()]
  def modes, do: @modes

  @doc "Stable `fallback_reason` tokens (ADR 0040 Decision 2)."
  @spec fallback_reasons() :: [String.t()]
  def fallback_reasons, do: @fallback_reasons

  @doc """
  Attach a `threshold_item` native replay window to local checkpoint data.

  `item_or_items` must be exactly the latest compaction item (`type` compaction,
  `id` matching `cmp_…`). A full compact `output` list is rejected as
  `threshold_item_not_singleton` — this helper never drops retained items to
  invent a singleton.

  Local text checkpoint fields remain mandatory on the same Event. This does
  not call the Provider and does not change live Turn ingest.
  """
  @spec persist_threshold_item(map(), map() | [map()], keyword()) ::
          {:ok, map()} | {:error, map()}
  def persist_threshold_item(local_event_data, item_or_items, opts \\ [])

  def persist_threshold_item(local_event_data, item_or_items, opts)
      when is_map(local_event_data) do
    with :ok <- validate_local_checkpoint(local_event_data),
         {:ok, items} <- threshold_items(item_or_items),
         {:ok, replay} <- capturing_replay("threshold_item", items, opts),
         {:ok, validated} <- validate_native_replay(replay),
         {:ok, local} <- safe_stringify_map(local_event_data) do
      {:ok, Map.put(local, "native_replay", validated)}
    end
  end

  def persist_threshold_item(_local_event_data, _item_or_items, _opts) do
    {:error,
     Tool.error(:invalid_args, "local history_compaction data must be a map", %{
       field: "event_data"
     })}
  end

  @doc """
  Persist a live `threshold_item` capture without failing the local checkpoint.

  Usable singleton `cmp_` items are stored as today. Missing, malformed, or
  forced-fallback captures still return local text plus `recorded_usable` false.
  """
  @spec persist_threshold_capture(map(), term(), keyword()) :: {:ok, map()} | {:error, map()}
  def persist_threshold_capture(local_event_data, item_or_items, opts \\ [])

  def persist_threshold_capture(local_event_data, item_or_items, opts)
      when is_map(local_event_data) do
    case persist_threshold_item(local_event_data, item_or_items || [], opts) do
      {:ok, data} ->
        {:ok, Map.put(data, "native_replay", maybe_force_fallback(data["native_replay"], opts))}

      {:error, _error} ->
        with :ok <- validate_local_checkpoint(local_event_data),
             {:ok, local} <- safe_stringify_map(local_event_data) do
          items =
            case capture_items(item_or_items) do
              {:ok, captured} -> captured
              {:error, _} -> []
            end

          {:ok, replay} = capturing_replay("threshold_item", items, opts)
          reason = forced_or_default_fallback(opts, capture_fallback_reason(item_or_items, items))
          {:ok, Map.put(local, "native_replay", unusable_replay(replay, reason))}
        end
    end
  end

  def persist_threshold_capture(_local_event_data, _item_or_items, _opts) do
    {:error,
     Tool.error(:invalid_args, "local history_compaction data must be a map", %{
       field: "event_data"
     })}
  end

  @doc """
  Attach a `standalone_window` native replay from a compact `output` list.

  Persists the entire `output` array. Reducing that list to `cmp_` alone is
  `standalone_window_pruned`. Local text checkpoint fields remain mandatory.
  """
  @spec persist_standalone_window(map(), term(), keyword()) :: {:ok, map()} | {:error, map()}
  def persist_standalone_window(local_event_data, output, opts \\ [])

  def persist_standalone_window(local_event_data, output, opts)
      when is_map(local_event_data) do
    with :ok <- validate_local_checkpoint(local_event_data),
         {:ok, items} <- standalone_items(output),
         {:ok, replay} <- capturing_replay("standalone_window", items, opts),
         {:ok, local} <- safe_stringify_map(local_event_data) do
      compact_output = compact_output_for_validate(opts, output, items)

      case validate_native_replay(replay, compact_output: compact_output) do
        {:ok, validated} ->
          {:ok, Map.put(local, "native_replay", maybe_force_fallback(validated, opts))}

        {:error, _error} ->
          {:ok,
           Map.put(
             local,
             "native_replay",
             unusable_replay(replay, forced_or_default_fallback(opts, "malformed_native_replay"))
           )}
      end
    end
  end

  def persist_standalone_window(_local_event_data, _output, _opts) do
    {:error,
     Tool.error(:invalid_args, "local history_compaction data must be a map", %{
       field: "event_data"
     })}
  end

  @doc """
  Overlay bit after Provider/backend resolve (ADR 0022 late-bound pattern).

  `preference` is `nil` (no preference), `true` (request on), or `false`
  (explicit off). `identity` carries string `provider`, `backend`,
  `dialect`, and optional `responses_host` from the resolved request.

  Overlay on is not standalone C. `chatgpt_codex` enables D
  (`compact_threshold`). Official `api.openai.com` enables D and may POST C.
  Other `open_responses` hosts stay local.
  """
  @spec overlay_after_resolve(nil | boolean(), map()) :: {:on, nil} | {:off, String.t()}
  def overlay_after_resolve(preference, identity) when is_map(identity) do
    provider = map_get(identity, "provider")
    dialect = map_get(identity, "dialect")
    host = responses_host_token(identity)

    cond do
      anthropic_identity?(provider, dialect) ->
        {:off, "native_unavailable"}

      preference == false ->
        {:off, "overlay_off"}

      provider == "openai_responses" and host in ["chatgpt_codex", "official_responses"] ->
        {:on, nil}

      true ->
        {:off, "native_unavailable"}
    end
  end

  def overlay_after_resolve(_preference, _identity), do: {:off, "native_unavailable"}

  @doc "Capturing identity map used to persist and fold a native window."
  @spec capturing_identity(keyword()) :: map()
  def capturing_identity(opts) when is_list(opts) do
    %{
      "provider" => capturing_string(opts, :provider, "openai_responses"),
      "backend" => capturing_string(opts, :backend),
      "dialect" => capturing_string(opts, :dialect),
      "model" => capturing_string(opts, :model)
    }
  end

  @doc """
  Validate a `native_replay` map for either persist mode.

  Returns `{:ok, normalized}` with `recorded_usable` set. Unusable windows keep
  the payload and set `fallback_reason`. Completely unparseable input returns
  `{:error, structured}`.

  Pass `compact_output:` when validating `standalone_window` so a reduced
  `items` list (save-only-`cmp_`) is `standalone_window_pruned`.
  """
  @spec validate_native_replay(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_native_replay(native_replay, opts \\ [])

  def validate_native_replay(native_replay, opts) when is_map(native_replay) do
    replay = stringify_keys(native_replay)

    if string_keyed_map?(replay) do
      {:ok, assess_native_replay(replay, opts)}
    else
      {:error,
       Tool.error(:malformed_native_replay, "native_replay must be a string-keyed map", %{})}
    end
  rescue
    ArgumentError ->
      {:error,
       Tool.error(:malformed_native_replay, "native_replay must be a string-keyed map", %{})}
  end

  def validate_native_replay(_native_replay, _opts) do
    {:error, Tool.error(:malformed_native_replay, "native_replay must be a map", %{})}
  end

  @doc """
  Bounded inspect projection: mode, usability, item ids, fallback reason.

  Never includes `items` or `encrypted_content`. Accepts either checkpoint
  `data` or a `native_replay` map. Returns `nil` when no native replay is present.
  """
  @spec inspect_native_replay(term()) :: map() | nil
  def inspect_native_replay(data) when is_map(data) do
    cond do
      is_map(map_get(data, "native_replay")) ->
        inspect_replay_map(map_get(data, "native_replay"))

      map_get(data, "mode") in @modes ->
        inspect_replay_map(data)

      true ->
        nil
    end
  end

  def inspect_native_replay(_data), do: nil

  @doc """
  Replace a checkpoint's `native_replay` with the inspect projection and drop
  any `encrypted_content` keys. Used by CLI `--json` and diagnostics.
  """
  @spec project_checkpoint_for_inspect(map()) :: map()
  def project_checkpoint_for_inspect(data) when is_map(data) do
    {replay, rest} = pop_native_replay(data)

    rest
    |> drop_encrypted_content()
    |> then(fn checkpoint ->
      case inspect_native_replay(replay || checkpoint) do
        nil -> checkpoint
        inspected -> Map.put(checkpoint, "native_replay", inspected)
      end
    end)
  end

  @doc "Sanitize a compact/complete result so JSON never prints ciphertext."
  @spec project_compact_result_for_inspect(map()) :: map()
  def project_compact_result_for_inspect(result) when is_map(result) do
    result
    |> update_string_map("event", &project_checkpoint_for_inspect/1)
    |> update_string_map("checkpoint", fn checkpoint ->
      update_string_map(checkpoint, "data", &project_checkpoint_for_inspect/1)
    end)
    |> drop_encrypted_content()
  end

  @doc """
  Fold-usable predicate for Provider replay.

  Returns true when `native_replay` is present, `recorded_usable`, still
  validates, and current Provider/backend/dialect/model match the capturing
  values. Anthropic fold never consults this predicate.
  """
  @spec fold_usable?(map(), map()) :: boolean()
  def fold_usable?(event_data, current) when is_map(event_data) and is_map(current) do
    replay = map_get(event_data, "native_replay")

    with true <- is_map(replay),
         true <- map_get(replay, "recorded_usable") == true,
         {:ok, validated} <- validate_native_replay(replay),
         true <- map_get(validated, "recorded_usable") == true,
         true <- capturing_matches?(validated, current) do
      true
    else
      _ -> false
    end
  end

  def fold_usable?(_event_data, _current), do: false

  defp threshold_items(item) when is_map(item), do: threshold_items([item])

  defp threshold_items(items) when is_list(items) do
    case safe_stringify_list(items) do
      {:ok, string_items} ->
        if threshold_singleton?(string_items) do
          {:ok, string_items}
        else
          {:error,
           Tool.error(
             :threshold_item_not_singleton,
             "threshold_item items must be exactly the latest cmp_ compaction item",
             %{
               item_count: length(string_items),
               compaction_item_ids: compaction_item_ids(string_items)
             }
           )}
        end

      {:error, _} = error ->
        error
    end
  end

  defp threshold_items(_items) do
    {:error,
     Tool.error(
       :threshold_item_not_singleton,
       "threshold_item items must be exactly the latest cmp_ compaction item",
       %{}
     )}
  end

  defp validate_local_checkpoint(data) when is_map(data) do
    case safe_stringify_map(data) do
      {:ok, data} ->
        missing =
          Enum.filter(@local_required, fn key ->
            not Map.has_key?(data, key) or blank_local_field?(key, data[key])
          end)

        cond do
          missing != [] ->
            {:error,
             Tool.error(:invalid_args, "local text checkpoint fields remain mandatory", %{
               missing: missing
             })}

          not valid_range?(data["range"]) ->
            {:error,
             Tool.error(:invalid_args, "local text checkpoint fields remain mandatory", %{
               missing: ["range"]
             })}

          true ->
            :ok
        end

      {:error, _} = error ->
        error
    end
  end

  defp blank_local_field?("limitations", value), do: not is_list(value)
  defp blank_local_field?("range", value), do: not is_map(value)

  defp blank_local_field?(_key, value) when is_binary(value), do: String.trim(value) == ""
  defp blank_local_field?(_key, _value), do: true

  defp valid_range?(%{"from_seq" => from, "to_seq" => to})
       when is_integer(from) and is_integer(to),
       do: true

  defp valid_range?(_range), do: false

  defp assess_native_replay(replay, opts) do
    items = replay["items"]
    mode = replay["mode"]
    compact_output = Keyword.get(opts, :compact_output)

    {usable, reason} =
      cond do
        not string_keyed_map?(replay) ->
          {false, "malformed_native_replay"}

        mode not in @modes ->
          {false, "malformed_native_replay"}

        missing_capturing_fields?(replay) ->
          {false, "malformed_native_replay"}

        mode == "standalone_window" and standalone_pruned?(items, compact_output) ->
          {false, "standalone_window_pruned"}

        not is_list(items) or items == [] ->
          {false, "malformed_native_replay"}

        compaction_items(items) == [] ->
          {false, "missing_compaction_item"}

        Enum.any?(compaction_items(items), &(not encrypted_content_present?(&1))) ->
          {false, "missing_encrypted_content"}

        mode == "threshold_item" and not threshold_singleton?(items) ->
          {false, "threshold_item_not_singleton"}

        unpaired_function_call?(items) ->
          {false, "unpaired_function_call"}

        true ->
          {true, nil}
      end

    replay
    |> Map.put("items", normalize_items(items))
    |> Map.put("compaction_item_ids", compaction_item_ids(items))
    |> Map.put("recorded_usable", usable)
    |> then(fn normalized ->
      if usable do
        Map.delete(normalized, "fallback_reason")
      else
        Map.put(normalized, "fallback_reason", reason)
      end
    end)
  end

  defp missing_capturing_fields?(replay) do
    Enum.any?(["provider", "backend", "dialect", "model"], fn key ->
      value = replay[key]
      not is_binary(value) or String.trim(value) == ""
    end)
  end

  defp standalone_pruned?(items, _compact_output) when not is_list(items), do: true

  defp standalone_pruned?(items, compact_output) when is_list(compact_output) do
    source = Enum.map(compact_output, &stringify_keys/1)
    normalized_items = Enum.map(items, &stringify_keys/1)

    source != normalized_items or
      (length(source) > 1 and only_compaction_items?(normalized_items))
  end

  defp standalone_pruned?(_items, _compact_output), do: false

  defp threshold_singleton?([item]) when is_map(item), do: compaction_item?(item)
  defp threshold_singleton?(_items), do: false

  defp only_compaction_items?(items) when is_list(items) and items != [] do
    Enum.all?(items, &compaction_item?/1)
  end

  defp only_compaction_items?(_items), do: false

  defp compaction_items(items) when is_list(items), do: Enum.filter(items, &compaction_item?/1)

  defp compaction_item_ids(items) when is_list(items) do
    items
    |> compaction_items()
    |> Enum.map(& &1["id"])
    |> Enum.filter(&is_binary/1)
  end

  defp compaction_item_ids(_items), do: []

  defp compaction_item?(item) when is_map(item) do
    type = map_get(item, "type")
    id = map_get(item, "id")
    is_binary(type) and type == "compaction" and is_binary(id) and String.starts_with?(id, "cmp_")
  end

  defp compaction_item?(_item), do: false

  defp encrypted_content_present?(item) when is_map(item) do
    content = map_get(item, "encrypted_content")
    is_binary(content) and String.trim(content) != ""
  end

  defp encrypted_content_present?(_item), do: false

  defp unpaired_function_call?(items) do
    output_ids =
      items
      |> Enum.filter(&function_call_output?/1)
      |> Enum.map(&function_call_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.any?(items, fn item ->
      function_call?(item) and
        case function_call_id(item) do
          nil -> true
          id -> not MapSet.member?(output_ids, id)
        end
    end)
  end

  defp function_call?(item) when is_map(item), do: map_get(item, "type") == "function_call"
  defp function_call?(_item), do: false

  defp function_call_output?(item) when is_map(item) do
    map_get(item, "type") in ["function_call_output", "function_call_result"]
  end

  defp function_call_output?(_item), do: false

  defp function_call_id(item) when is_map(item) do
    case map_get(item, "call_id") do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp normalize_items(items) when is_list(items), do: Enum.map(items, &stringify_keys/1)
  defp normalize_items(items), do: items

  defp capturing_matches?(replay, current) do
    Enum.all?(["provider", "backend", "dialect", "model"], fn key ->
      map_get(replay, key) == map_get(current, key)
    end)
  end

  defp capturing_string(opts, key, default \\ nil) do
    case Keyword.get(opts, key, default) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp capturing_replay(mode, items, opts) do
    {:ok,
     %{
       "mode" => mode,
       "provider" => capturing_string(opts, :provider, "openai_responses"),
       "backend" => capturing_string(opts, :backend),
       "dialect" => capturing_string(opts, :dialect),
       "model" => capturing_string(opts, :model),
       "items" => items
     }}
  end

  defp standalone_items(items) when is_list(items), do: safe_stringify_list(items)
  defp standalone_items(_items), do: {:ok, []}

  defp capture_items(nil), do: {:ok, []}
  defp capture_items(item) when is_map(item), do: capture_items([item])

  defp capture_items(items) when is_list(items) do
    case safe_stringify_list(items) do
      {:ok, string_items} -> {:ok, string_items}
      {:error, _} -> {:ok, []}
    end
  end

  defp capture_items(_items), do: {:ok, []}

  defp capture_fallback_reason(nil, _items), do: "missing_compaction_item"
  defp capture_fallback_reason([], _items), do: "missing_compaction_item"

  defp capture_fallback_reason(_original, items) do
    cond do
      items == [] -> "missing_compaction_item"
      not threshold_singleton?(items) -> "threshold_item_not_singleton"
      Enum.any?(items, &(not encrypted_content_present?(&1))) -> "missing_encrypted_content"
      true -> "malformed_native_replay"
    end
  end

  defp compact_output_for_validate(opts, output, items) do
    case Keyword.get(opts, :compact_output, output) do
      list when is_list(list) -> list
      _ -> items
    end
  end

  defp maybe_force_fallback(validated, opts) do
    case forced_fallback(opts) do
      nil ->
        validated

      reason ->
        validated
        |> Map.put("recorded_usable", false)
        |> Map.put("fallback_reason", reason)
    end
  end

  defp forced_or_default_fallback(opts, default) do
    forced_fallback(opts) || default
  end

  defp forced_fallback(opts) do
    case Keyword.get(opts, :fallback_reason) do
      reason when is_binary(reason) and reason in @fallback_reasons -> reason
      _ -> nil
    end
  end

  defp unusable_replay(replay, reason) when is_map(replay) do
    replay
    |> Map.put("items", normalize_items(replay["items"]))
    |> Map.put("compaction_item_ids", compaction_item_ids(replay["items"]))
    |> Map.put("recorded_usable", false)
    |> Map.put("fallback_reason", reason)
  end

  defp anthropic_identity?(provider, dialect) do
    provider in ["anthropic", "Pixir.Providers.Anthropic"] or dialect == "anthropic"
  end

  defp responses_host_token(identity) when is_map(identity) do
    case map_get(identity, "responses_host") do
      host when host in ["chatgpt_codex", "official_responses", "other"] ->
        host

      _missing ->
        case map_get(identity, "backend") do
          "chatgpt_codex" -> "chatgpt_codex"
          _other -> "other"
        end
    end
  end

  defp safe_stringify_map(map) when is_map(map) do
    {:ok, stringify_keys(map)}
  rescue
    ArgumentError ->
      {:error,
       Tool.error(:malformed_native_replay, "native_replay must be a string-keyed map", %{})}
  end

  defp safe_stringify_list(list) when is_list(list) do
    {:ok, Enum.map(list, &stringify_keys/1)}
  rescue
    ArgumentError ->
      {:error,
       Tool.error(:malformed_native_replay, "native_replay must be a string-keyed map", %{})}
  end

  defp inspect_replay_map(replay) when is_map(replay) do
    inspected = %{
      "mode" => map_get(replay, "mode"),
      "recorded_usable" => map_get(replay, "recorded_usable"),
      "compaction_item_ids" => map_get(replay, "compaction_item_ids") || []
    }

    inspected =
      case map_get(replay, "fallback_reason") do
        reason when is_binary(reason) and reason != "" ->
          Map.put(inspected, "fallback_reason", reason)

        _ ->
          inspected
      end

    inspected
    |> Map.drop(["items", "encrypted_content"])
    |> drop_encrypted_content()
  end

  defp inspect_replay_map(_replay), do: nil

  defp pop_native_replay(data) when is_map(data) do
    cond do
      Map.has_key?(data, "native_replay") -> Map.pop(data, "native_replay")
      Map.has_key?(data, :native_replay) -> Map.pop(data, :native_replay)
      true -> {nil, data}
    end
  end

  # Avoid String.to_existing_atom on data keys. Only rewrite known result keys.
  defp update_string_map(map, "event", fun) when is_map(map) do
    cond do
      is_map(map["event"]) -> Map.update!(map, "event", fun)
      is_map(Map.get(map, :event)) -> Map.update!(map, :event, fun)
      true -> map
    end
  end

  defp update_string_map(map, "checkpoint", fun) when is_map(map) do
    cond do
      is_map(map["checkpoint"]) -> Map.update!(map, "checkpoint", fun)
      is_map(Map.get(map, :checkpoint)) -> Map.update!(map, :checkpoint, fun)
      true -> map
    end
  end

  defp update_string_map(map, "data", fun) when is_map(map) do
    cond do
      is_map(map["data"]) -> Map.update!(map, "data", fun)
      is_map(Map.get(map, :data)) -> Map.update!(map, :data, fun)
      true -> map
    end
  end

  defp update_string_map(map, _key, _fun), do: map

  defp drop_encrypted_content(value) when is_map(value) do
    value
    |> Map.drop(["encrypted_content", :encrypted_content])
    |> Map.new(fn {key, nested} -> {key, drop_encrypted_content(nested)} end)
  end

  defp drop_encrypted_content(value) when is_list(value),
    do: Enum.map(value, &drop_encrypted_content/1)

  defp drop_encrypted_content(value), do: value

  defp string_keyed_map?(map) when is_map(map) do
    Enum.all?(map, fn
      {key, value} when is_binary(key) ->
        cond do
          is_map(value) -> string_keyed_map?(value)
          is_list(value) -> Enum.all?(value, &(not is_map(&1) or string_keyed_map?(&1)))
          true -> true
        end

      _ ->
        false
    end)
  end

  defp string_keyed_map?(_map), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        {key, stringify_keys(value)}

      {key, value} when is_atom(key) ->
        {Atom.to_string(key), stringify_keys(value)}

      {key, _value} ->
        raise ArgumentError, "native_replay key must be a string or atom, got: #{inspect(key)}"
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      true ->
        Enum.find_value(map, fn
          {existing, value} when is_atom(existing) ->
            if Atom.to_string(existing) == key, do: value

          _ ->
            nil
        end)
    end
  end
end
