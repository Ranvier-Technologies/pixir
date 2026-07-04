defmodule Pixir.Provider.Cache do
  @moduledoc """
  Prompt-cache key helpers for the OpenAI Responses dialect.

  A cache key is a routing hint for a stable prefix family. It must be short and safe:
  no raw workspace paths, user text, request ids, timestamps, emails, or secrets. The
  Provider still combines this hint with its own prompt-prefix hash; Pixir treats the key
  as optimization metadata, never as durable state.
  """

  @max_key_bytes 96
  @hash_bytes 8

  # The Prompt Contract version (ADR 0020): the leading key segment names the
  # instructions/input layering this request family was built under. Bump it on
  # every prompt-contract change so an intentional fleet-wide cache break is
  # attributable in provider_usage evidence — never an unexplained hit-rate drop.
  # px1 = workspace path in the first instructions sentence. px2 = byte-stable
  # Layer 0 (discovery rule + checkpoint contract), late developer context.
  # px3 = Skill index rendered as routing-only metadata with when_to_use fields.
  @prompt_contract_version "px3"

  @doc "The current Prompt Contract version segment (leads every cache key)."
  @spec prompt_contract_version() :: String.t()
  def prompt_contract_version, do: @prompt_contract_version

  @doc """
  Build safe prompt-cache metadata for one Provider call.

  Expected fields are `:session_id`, `:model`, `:mode`, `:tools`, and `:skill_index`;
  `:fork_root_session_id` is optional and defaults to `:session_id` (a fork passes its
  fork-tree ROOT so the whole tree shares one cache family — ADR 0020).
  Returns a string-keyed map so it can be copied into a `provider_usage` Event.
  """
  @spec metadata(map()) :: {:ok, map()} | {:error, :invalid_args}
  def metadata(
        %{
          session_id: sid,
          model: model,
          mode: mode,
          tools: tools,
          skill_index: skill_index
        } = input
      ) do
    fork_root = normalize_fork_root(Map.get(input, :fork_root_session_id), sid)

    with {:ok, toolset_hash} <- stable_hash(tools),
         {:ok, skill_index_hash} <- stable_hash(skill_index),
         {:ok, session_family_hash} <- stable_hash(fork_root) do
      key =
        [
          @prompt_contract_version,
          "m_" <> slug(model, 14),
          "r_" <> slug(to_string(mode), 6),
          "s_" <> session_family_hash,
          "t_" <> toolset_hash,
          "k_" <> skill_index_hash
        ]
        |> Enum.join(":")
        |> byte_slice(@max_key_bytes)

      {:ok,
       %{
         "prompt_cache_key" => key,
         "prompt_contract_version" => @prompt_contract_version,
         "toolset_hash" => toolset_hash,
         "skill_index_hash" => skill_index_hash,
         "session_family_hash" => session_family_hash
       }}
    else
      # Never leak a raw exception from stable_hash — the spec promises
      # {:error, :invalid_args}, and callers degrade on that atom (a struct here
      # crashed the Turn task via to_string/1 before this clause existed).
      {:error, _hash_failure} -> {:error, :invalid_args}
    end
  end

  def metadata(_input), do: {:error, :invalid_args}

  defp normalize_fork_root(root, _sid) when is_binary(root) and root != "", do: root
  defp normalize_fork_root(_root, sid), do: sid

  @doc "Return a stable short hash for maps, lists, and scalar values."
  @spec stable_hash(term()) :: {:ok, String.t()} | {:error, term()}
  def stable_hash(term) do
    {:ok, stable_hash_raw(term)}
  rescue
    error -> {:error, error}
  end

  defp stable_hash_raw(term) do
    term
    |> stable_term()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_bytes * 2)
  end

  defp stable_term(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), stable_term(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp stable_term(list) when is_list(list), do: Enum.map(list, &stable_term/1)
  defp stable_term(value), do: value

  defp slug(value, max) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      safe -> safe
    end
    |> byte_slice(max)
  end

  defp byte_slice(text, max) when byte_size(text) <= max, do: text

  defp byte_slice(text, max) do
    text
    |> binary_part(0, max)
    |> String.split("", trim: true)
    |> Enum.join()
  rescue
    ArgumentError ->
      text
      |> String.to_charlist()
      |> take_bytes(max, [], 0)
      |> List.to_string()
  end

  defp take_bytes(_chars, max, acc, bytes) when bytes >= max, do: Enum.reverse(acc)
  defp take_bytes([], _max, acc, _bytes), do: Enum.reverse(acc)

  defp take_bytes([char | rest], max, acc, bytes) do
    char_bytes = char |> List.wrap() |> List.to_string() |> byte_size()

    if bytes + char_bytes <= max do
      take_bytes(rest, max, [char | acc], bytes + char_bytes)
    else
      Enum.reverse(acc)
    end
  end
end
