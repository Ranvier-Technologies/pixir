defmodule Mix.Tasks.Pixir.Cache.Reconcile do
  @shortdoc "Reconcile provider prompt-cache evidence from local session logs"

  @moduledoc """
  Folds durable `provider_usage` events from `.pixir/sessions/*.ndjson` and emits
  prompt-cache family accounting as JSON.

  Usage:

      mix pixir.cache.reconcile
      mix pixir.cache.reconcile --sessions-dir .pixir/sessions
      mix pixir.cache.reconcile --help

  The task is offline-only. `below_minimum_count` records expected Anthropic pa1 calls
  where a cache plan existed but both creation and read counters were zero (for
  example, below the 512-token minimum cacheable prefix).
  """

  use Mix.Task

  @command "mix pixir.cache.reconcile"
  @switches [sessions_dir: :string, help: :boolean]
  @aliases [h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        print_json(%{
          "ok" => false,
          "error" => %{"kind" => "invalid_options", "invalid" => inspect(invalid)}
        })

      true ->
        sessions_dir = Keyword.get(opts, :sessions_dir, ".pixir/sessions")

        payload = %{
          "ok" => true,
          "command" => @command,
          "sessions_dir" => sessions_dir,
          "families" => reconcile(sessions_dir)
        }

        print_json(payload)
    end
  end

  defp reconcile(sessions_dir) do
    sessions_dir
    |> Path.join("*.ndjson")
    |> Path.wildcard()
    |> Enum.flat_map(&events_from_file/1)
    |> Enum.filter(&(Map.get(&1, "type") == "provider_usage"))
    |> Enum.reduce(%{}, &accumulate_event/2)
    |> Enum.map(fn {_key, family} -> finalize_family(family) end)
    |> Enum.sort_by(&family_sort_key/1)
  end

  defp events_from_file(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, event} when is_map(event) -> [event]
        _ -> []
      end
    end)
  rescue
    _ -> []
  end

  defp accumulate_event(event, acc) do
    data = Map.get(event, "data", %{}) || %{}
    summary = Map.get(data, "usage_summary", %{}) || %{}
    cache = Map.get(summary, "cache", %{}) || %{}

    # Turn merges cache metadata FLAT into the event data (turn.ex
    # record_provider_usage/6), so the family fields live at the top level of
    # `data`, never under a nested "cache_metadata" key.
    family_key = %{
      "prompt_contract_version" => Map.get(data, "prompt_contract_version"),
      "toolset_hash" => Map.get(data, "toolset_hash"),
      "skill_index_hash" => Map.get(data, "skill_index_hash"),
      "session_family_hash" => Map.get(data, "session_family_hash")
    }

    key = Jason.encode!(family_key)

    family =
      Map.get(acc, key) ||
        Map.merge(family_key, %{
          "calls" => 0,
          "input_tokens" => 0,
          "creation_tokens" => 0,
          "read_tokens" => 0,
          "below_minimum_count" => 0
        })

    input_tokens = token(summary, "input_tokens")
    creation_tokens = token(cache, "creation_tokens")

    # Events recorded before the explicit cache map carry reads only as the
    # OpenAI-normalized cached_tokens; fold them rather than dropping history.
    read_tokens =
      case Map.get(cache, "read_tokens") do
        value when is_integer(value) and value >= 0 -> value
        _ -> token(summary, "cached_tokens")
      end

    family = %{
      family
      | "calls" => family["calls"] + 1,
        "input_tokens" => family["input_tokens"] + input_tokens,
        "creation_tokens" => family["creation_tokens"] + creation_tokens,
        "read_tokens" => family["read_tokens"] + read_tokens,
        "below_minimum_count" =>
          family["below_minimum_count"] + below_minimum(family_key, creation_tokens, read_tokens)
    }

    Map.put(acc, key, family)
  end

  defp below_minimum(%{"prompt_contract_version" => "pa1"}, 0, 0), do: 1
  defp below_minimum(_metadata, _creation, _reads), do: 0

  defp finalize_family(family) do
    denominator = family["input_tokens"] + family["creation_tokens"] + family["read_tokens"]
    hit_rate = if denominator > 0, do: family["read_tokens"] / denominator, else: nil
    Map.put(family, "hit_rate", hit_rate)
  end

  defp family_sort_key(family) do
    [
      family["prompt_contract_version"] || "",
      family["session_family_hash"] || "",
      family["toolset_hash"] || "",
      family["skill_index_hash"] || ""
    ]
  end

  defp token(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp token(_map, _key), do: 0

  defp print_json(payload), do: Mix.shell().info(Jason.encode!(payload, pretty: true))
end
