defmodule Pixir.Provider.HostedTools do
  @moduledoc """
  Request shaping for Provider-hosted OpenAI tools.

  These are not Pixir local `Tool`s. Pixir does not execute them, does not record them
  as `tool_call` / `tool_result`, and does not ask `Pixir.Tools.Executor` to run them.
  They are Provider-side capabilities declared in the Responses request body. Pixir's
  job is to shape the request deliberately and later persist bounded Provider evidence.
  """

  @valid_search_context_sizes ~w(low medium high)
  @valid_return_token_budgets ~w(default unlimited)
  @source_include "web_search_call.action.sources"
  @web_search_tool_fields ~w(
    type
    search_context_size
    filters
    user_location
    external_web_access
    return_token_budget
    search_content_types
    image_settings
  )
  @web_search_config_fields ["enabled", "include_sources" | @web_search_tool_fields]

  @type error_reason :: %{
          required(:kind) => :invalid_args,
          required(:message) => String.t(),
          required(:details) => map()
        }

  @doc """
  The full `web_search` config vocabulary (config-only flags plus tool fields).

  Single source of truth for every parser of this shape: `Pixir.Config` validates
  config.json against this same list so the two can never drift.
  """
  @spec web_search_config_fields() :: [String.t()]
  def web_search_config_fields, do: @web_search_config_fields

  @doc """
  Build an OpenAI hosted `web_search` tool spec.

  Pixir defaults `search_context_size` to `"low"` for beta ergonomics and cost
  discipline. Supported OpenAI search policy fields are preserved; unsupported fields
  return structured `:invalid_args` instead of silently changing policy.
  `include_sources` is intentionally not part of the tool object; it drives the
  Responses `include` list via `include_fields/2`.
  """
  @spec web_search(map() | keyword() | boolean() | nil) ::
          {:ok, map() | nil} | {:error, error_reason()}
  def web_search(nil), do: {:ok, nil}
  def web_search(false), do: {:ok, nil}
  def web_search(true), do: web_search(%{})

  def web_search(opts) when is_list(opts) do
    normalize_web_search(opts)
  end

  def web_search(opts) when is_map(opts) and not is_struct(opts) do
    normalize_web_search(opts)
  end

  def web_search(other) do
    {:error,
     invalid("web_search must be a plain map, keyword list, boolean, or nil.", %{
       "received_type" => value_type(other)
     })}
  end

  defp normalize_web_search(opts) do
    with {:ok, opts} <- safe_normalize_map(opts) do
      if field(opts, "enabled") == false do
        {:ok, nil}
      else
        normalize_web_search_tool(opts, @web_search_config_fields)
      end
    end
  end

  @doc """
  Extract Provider-hosted tool specs from a Provider request.

  Supported request fields:

    * `:web_search` / `"web_search"` - Pixir-owned config for the hosted web search
      tool;
    * `:hosted_tools` / `"hosted_tools"` - raw hosted tool specs for tests or future
      Provider-hosted tools.
  """
  @spec from_request(map()) :: {:ok, [map()]} | {:error, error_reason()}
  def from_request(request) when is_map(request) do
    with :ok <- reject_request_key_collisions(request, ["web_search", "hosted_tools"]),
         {:ok, raw_tools} <- normalize_hosted_tools(field(request, "hosted_tools") || []),
         {:ok, web_search_tool} <- web_search(field(request, "web_search")),
         {:ok, raw_has_web_search?} <- web_search_requested?(raw_tools) do
      tools =
        if is_nil(web_search_tool) or raw_has_web_search? do
          raw_tools
        else
          raw_tools ++ [web_search_tool]
        end

      {:ok, tools}
    end
  end

  def from_request(_request), do: {:ok, []}

  @doc """
  Responses `include` fields needed by the declared hosted tools.

  Web search source evidence is included by default whenever web search is enabled.
  Callers may set `web_search.include_sources: false` to suppress it for a targeted
  probe.
  """
  @spec include_fields(map(), [map()]) :: {:ok, [String.t()]} | {:error, error_reason()}
  def include_fields(request, hosted_tools)
      when is_map(request) and not is_struct(request) and is_list(hosted_tools) do
    with :ok <- reject_request_key_collisions(request, ["web_search"]),
         {:ok, requested?} <- web_search_requested?(hosted_tools),
         {:ok, include_sources?} <- include_sources?(request) do
      if requested? and include_sources? do
        {:ok, [@source_include]}
      else
        {:ok, []}
      end
    end
  end

  def include_fields(_request, _hosted_tools) do
    {:error,
     invalid("include_fields requires a request map and hosted tool list.", %{
       "expected" => "include_fields(request_map, hosted_tools_list)"
     })}
  end

  @doc "True when the hosted tool list contains OpenAI web search."
  @spec web_search_requested?([map()]) :: {:ok, boolean()} | {:error, error_reason()}
  def web_search_requested?(hosted_tools) when is_list(hosted_tools) do
    if proper_list?(hosted_tools) do
      {:ok, Enum.any?(hosted_tools, &(field(&1, "type") == "web_search"))}
    else
      invalid_hosted_tools_list()
    end
  end

  def web_search_requested?(_hosted_tools), do: invalid_hosted_tools_list()

  defp normalize_hosted_tools(tools) when is_list(tools) do
    if proper_list?(tools) do
      Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
        case normalize_hosted_tool(tool) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        {:error, _} = error -> error
      end
    else
      invalid_hosted_tools_list()
    end
  end

  defp normalize_hosted_tools(_other), do: invalid_hosted_tools_list()

  defp normalize_hosted_tool(tool) when is_list(tool) do
    normalize_hosted_tool_map(tool)
  end

  defp normalize_hosted_tool(tool) when is_map(tool) and not is_struct(tool) do
    normalize_hosted_tool_map(tool)
  end

  defp normalize_hosted_tool(other) do
    {:error,
     invalid("Hosted tool specs must be plain maps or keyword lists.", %{
       "received_type" => value_type(other)
     })}
  end

  defp normalize_hosted_tool_map(tool) do
    with {:ok, normalized} <- safe_normalize_map(tool) do
      case field(normalized, "type") do
        "web_search" ->
          validate_web_search_tool(normalized)

        type ->
          {:error,
           invalid("Unsupported Provider-hosted tool type.", %{
             "received_type" => value_type(type),
             "supported" => ["web_search"]
           })}
      end
    end
  end

  defp validate_web_search_tool(tool),
    do: normalize_web_search_tool(tool, @web_search_tool_fields)

  defp normalize_web_search_tool(source, allowed_fields) do
    with :ok <- reject_unsupported_fields(source, allowed_fields),
         :ok <- validate_web_search_type(source),
         {:ok, size} <- validate_search_context_size(field(source, "search_context_size")),
         base = %{"type" => "web_search", "search_context_size" => size},
         {:ok, acc} <- maybe_put_map(base, source, "filters"),
         {:ok, acc} <- maybe_put_map(acc, source, "user_location"),
         {:ok, acc} <- maybe_put_boolean(acc, source, "external_web_access"),
         {:ok, acc} <- maybe_put_return_token_budget(acc, source),
         {:ok, acc} <- maybe_put_string_list(acc, source, "search_content_types"),
         {:ok, acc} <- maybe_put_map(acc, source, "image_settings") do
      {:ok, acc}
    end
  end

  defp reject_unsupported_fields(tool, allowed_fields) do
    unsupported = tool |> Map.keys() |> Enum.reject(&(&1 in allowed_fields)) |> Enum.sort()

    if unsupported == [] do
      :ok
    else
      {:error,
       invalid("web_search contains unsupported field(s).", %{
         "reason" => "unsupported_fields",
         "supported" => Enum.sort(allowed_fields)
       })}
    end
  end

  defp validate_web_search_type(tool) do
    case field(tool, "type") do
      nil ->
        :ok

      "web_search" ->
        :ok

      type ->
        {:error,
         invalid("web_search.type must be \"web_search\".", %{
           "received_type" => value_type(type)
         })}
    end
  end

  defp validate_search_context_size(nil), do: {:ok, "low"}

  defp validate_search_context_size(size) when size in @valid_search_context_sizes,
    do: {:ok, size}

  defp validate_search_context_size(size) do
    {:error,
     invalid(
       "web_search.search_context_size must be one of: #{Enum.join(@valid_search_context_sizes, ", ")}.",
       %{"received_type" => value_type(size), "allowed" => @valid_search_context_sizes}
     )}
  end

  defp maybe_put_map(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      value when is_map(value) and not is_struct(value) ->
        case normalize_json_term(value) do
          {:ok, normalized} -> {:ok, Map.put(acc, key, normalized)}
          :error -> invalid_json_field(key, "map")
        end

      value ->
        invalid_json_field(key, value_type(value))
    end
  end

  defp maybe_put_boolean(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      value when is_boolean(value) ->
        {:ok, Map.put(acc, key, value)}

      value ->
        {:error,
         invalid("web_search.#{key} must be a boolean.", %{
           "received_type" => value_type(value)
         })}
    end
  end

  defp maybe_put_return_token_budget(acc, source) do
    case field(source, "return_token_budget") do
      nil ->
        {:ok, acc}

      value when value in @valid_return_token_budgets ->
        {:ok, Map.put(acc, "return_token_budget", value)}

      value ->
        {:error,
         invalid(
           "web_search.return_token_budget must be one of: #{Enum.join(@valid_return_token_budgets, ", ")}.",
           %{"received_type" => value_type(value), "allowed" => @valid_return_token_budgets}
         )}
    end
  end

  defp maybe_put_string_list(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      values when is_list(values) ->
        if proper_list?(values) and Enum.all?(values, &(is_binary(&1) and String.valid?(&1))) do
          {:ok, Map.put(acc, key, values)}
        else
          {:error,
           invalid("web_search.#{key} must be a list of UTF-8 strings.", %{
             "received_type" => "list"
           })}
        end

      value ->
        {:error,
         invalid("web_search.#{key} must be a list of UTF-8 strings.", %{
           "received_type" => value_type(value)
         })}
    end
  end

  defp include_sources?(request) do
    case field(request, "web_search") do
      config when is_map(config) or is_list(config) ->
        include_sources_from_config(config)

      _config ->
        {:ok, true}
    end
  end

  defp include_sources_from_config(config) do
    case safe_normalize_map(config) do
      {:ok, web_search_config} ->
        case field(web_search_config, "include_sources") do
          false -> {:ok, false}
          _ -> {:ok, true}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp safe_normalize_map(map) when is_map(map) and not is_struct(map),
    do: normalize_entries(Map.to_list(map))

  defp safe_normalize_map(keyword) when is_list(keyword) do
    if proper_list?(keyword), do: normalize_entries(keyword), else: invalid_normalized_map()
  end

  defp safe_normalize_map(_other), do: invalid_normalized_map()

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, value}, {:ok, acc} ->
        with {:ok, normalized_key} <- normalize_key(key),
             false <- Map.has_key?(acc, normalized_key) do
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
        else
          _ -> {:halt, invalid_normalized_map()}
        end

      _item, _acc ->
        {:halt, invalid_normalized_map()}
    end)
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp normalize_key(key) when is_binary(key) do
    if String.valid?(key), do: {:ok, key}, else: :error
  end

  defp normalize_key(_key), do: :error

  defp reject_request_key_collisions(request, keys) do
    if Enum.any?(keys, &dual_key?(request, &1)) do
      {:error,
       invalid("Provider request contains a normalized-key collision.", %{
         "reason" => "normalized_key_collision"
       })}
    else
      :ok
    end
  end

  defp dual_key?(request, key) do
    case existing_atom(key) do
      nil -> false
      atom_key -> Map.has_key?(request, key) and Map.has_key?(request, atom_key)
    end
  end

  defp normalize_json_term(value)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: {:ok, value}

  defp normalize_json_term(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp normalize_json_term(value) when is_list(value) do
    if proper_list?(value) do
      value
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
        case normalize_json_term(item) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp normalize_json_term(value) when is_map(value) and not is_struct(value) do
    case safe_normalize_map(value) do
      {:ok, normalized} ->
        Enum.reduce_while(normalized, {:ok, %{}}, fn {key, nested}, {:ok, acc} ->
          case normalize_json_term(nested) do
            {:ok, normalized_nested} ->
              {:cont, {:ok, Map.put(acc, key, normalized_nested)}}

            :error ->
              {:halt, :error}
          end
        end)

      {:error, _reason} ->
        :error
    end
  end

  defp normalize_json_term(_value), do: :error

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp invalid_normalized_map do
    {:error,
     invalid("Provider hosted tool config must be a plain map or proper keyword list.", %{
       "reason" => "invalid_map"
     })}
  end

  defp invalid_hosted_tools_list do
    {:error,
     invalid("hosted_tools must be a proper list of Provider-hosted tool specs.", %{
       "expected" => "proper_list"
     })}
  end

  defp invalid_json_field(key, received_type) do
    {:error,
     invalid("web_search.#{key} must be a JSON-safe plain map.", %{
       "received_type" => received_type
     })}
  end

  defp value_type(nil), do: "nil"
  defp value_type(value) when is_boolean(value), do: "boolean"
  defp value_type(value) when is_binary(value), do: "string"
  defp value_type(value) when is_atom(value), do: "atom"
  defp value_type(value) when is_integer(value), do: "integer"
  defp value_type(value) when is_float(value), do: "float"
  defp value_type(value) when is_list(value), do: "list"
  defp value_type(value) when is_struct(value), do: "struct"
  defp value_type(value) when is_map(value), do: "map"
  defp value_type(value) when is_tuple(value), do: "tuple"
  defp value_type(value) when is_function(value), do: "function"
  defp value_type(value) when is_pid(value), do: "pid"
  defp value_type(value) when is_reference(value), do: "reference"
  defp value_type(value) when is_port(value), do: "port"
  defp value_type(_value), do: "other"

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom(key) do
          nil -> nil
          atom_key -> Map.get(map, atom_key)
        end
    end
  end

  defp field(_other, _key), do: nil

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp invalid(message, details), do: %{kind: :invalid_args, message: message, details: details}
end
