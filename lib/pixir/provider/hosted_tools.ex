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

  def web_search(opts) when is_list(opts) or is_map(opts) do
    with {:ok, opts} <- safe_normalize_map(opts) do
      if field(opts, "enabled") == false do
        {:ok, nil}
      else
        normalize_web_search_tool(opts, @web_search_config_fields)
      end
    end
  end

  def web_search(other) do
    {:error,
     invalid("web_search must be a map, keyword list, boolean, or nil.", %{
       "value" => inspect(other)
     })}
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
    with {:ok, raw_tools} <- normalize_hosted_tools(field(request, "hosted_tools") || []),
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
  def include_fields(request, hosted_tools) when is_map(request) and is_list(hosted_tools) do
    with {:ok, requested?} <- web_search_requested?(hosted_tools) do
      if requested? and include_sources?(request) do
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
    {:ok, Enum.any?(hosted_tools, &(field(&1, "type") == "web_search"))}
  end

  def web_search_requested?(_hosted_tools) do
    {:error, invalid("hosted_tools must be a list.", %{"expected" => "list"})}
  end

  defp normalize_hosted_tools(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case normalize_hosted_tool(tool) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_hosted_tools(other) do
    {:error,
     invalid("hosted_tools must be a list of Provider-hosted tool specs.", %{
       "value" => inspect(other)
     })}
  end

  defp normalize_hosted_tool(tool) when is_map(tool) or is_list(tool) do
    with {:ok, normalized} <- safe_normalize_map(tool) do
      case field(normalized, "type") do
        "web_search" ->
          validate_web_search_tool(normalized)

        type ->
          {:error,
           invalid("Unsupported Provider-hosted tool type.", %{
             "type" => inspect(type),
             "supported" => ["web_search"]
           })}
      end
    end
  end

  defp normalize_hosted_tool(other) do
    {:error,
     invalid("Hosted tool specs must be maps.", %{
       "value" => inspect(other)
     })}
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
         "unsupported" => unsupported,
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
        {:error, invalid("web_search.type must be \"web_search\".", %{"value" => inspect(type)})}
    end
  end

  defp validate_search_context_size(nil), do: {:ok, "low"}

  defp validate_search_context_size(size) when size in @valid_search_context_sizes,
    do: {:ok, size}

  defp validate_search_context_size(size) do
    {:error,
     invalid(
       "web_search.search_context_size must be one of: #{Enum.join(@valid_search_context_sizes, ", ")}.",
       %{"value" => inspect(size), "allowed" => @valid_search_context_sizes}
     )}
  end

  defp maybe_put_map(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      value when is_map(value) ->
        {:ok, Map.put(acc, key, value)}

      value ->
        {:error, invalid("web_search.#{key} must be a map.", %{"value" => inspect(value)})}
    end
  end

  defp maybe_put_boolean(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      value when is_boolean(value) ->
        {:ok, Map.put(acc, key, value)}

      value ->
        {:error, invalid("web_search.#{key} must be a boolean.", %{"value" => inspect(value)})}
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
           %{"value" => inspect(value), "allowed" => @valid_return_token_budgets}
         )}
    end
  end

  defp maybe_put_string_list(acc, source, key) do
    case field(source, key) do
      nil ->
        {:ok, acc}

      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          {:ok, Map.put(acc, key, values)}
        else
          {:error,
           invalid("web_search.#{key} must be a list of strings.", %{"value" => inspect(values)})}
        end

      value ->
        {:error,
         invalid("web_search.#{key} must be a list of strings.", %{"value" => inspect(value)})}
    end
  end

  defp include_sources?(request) do
    case field(request, "web_search") do
      config when is_map(config) or is_list(config) ->
        include_sources_from_config(config)

      _config ->
        true
    end
  end

  defp include_sources_from_config(config) do
    case safe_normalize_map(config) do
      {:ok, web_search_config} ->
        case field(web_search_config, "include_sources") do
          false -> false
          _ -> true
        end

      {:error, _reason} ->
        true
    end
  end

  defp normalize_map(keyword) when is_list(keyword) do
    Enum.reduce(keyword, %{}, fn
      {key, value}, acc ->
        put_normalized_key!(acc, key, value)

      item, _acc ->
        raise ArgumentError,
              "Provider hosted tool keyword entries must be {key, value}, got: #{inspect(item)}"
    end)
  end

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      put_normalized_key!(acc, key, value)
    end)
  end

  defp put_normalized_key!(acc, key, value) do
    normalized_key = normalize_key!(key)

    if Map.has_key?(acc, normalized_key) do
      raise ArgumentError,
            "Provider hosted tool key collision after normalization: #{inspect(normalized_key)}"
    end

    Map.put(acc, normalized_key, value)
  end

  defp normalize_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key!(key) when is_binary(key), do: key

  defp normalize_key!(key),
    do:
      raise(
        ArgumentError,
        "Provider hosted tool keys must be strings or atoms, got: #{inspect(key)}"
      )

  defp safe_normalize_map(map_or_keyword) do
    {:ok, normalize_map(map_or_keyword)}
  rescue
    error in ArgumentError ->
      {:error, invalid(Exception.message(error), %{})}
  end

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
