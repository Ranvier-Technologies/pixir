defmodule Pixir.Providers.Anthropic.Tools do
  @moduledoc false

  alias Pixir.Tool

  @doc "Project Pixir/OpenAI Responses function-tool specs to Anthropic tool specs."
  @spec project(nil | [map()]) :: {:ok, nil | [map()]} | {:error, map()}
  def project(nil), do: {:ok, nil}

  def project(tools) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool, {:ok, acc} ->
      case project_one(tool) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, error} -> {:error, error}
    end
  end

  def project(_tools) do
    {:error,
     Tool.error(:invalid_args, "Anthropic request field must be a list.", %{
       field: :tools
     })}
  end

  defp project_one(%{"type" => "function"} = tool), do: function_tool(tool)
  defp project_one(%{type: "function"} = tool), do: function_tool(tool)
  defp project_one(%{type: :function} = tool), do: function_tool(tool)

  # A typeless map carrying name + input_schema is already Anthropic-native;
  # it passes through untouched (the P2 request contract accepted these
  # directly and its tests document that).
  defp project_one(%{} = tool)
       when not is_map_key(tool, "type") and not is_map_key(tool, :type) do
    with {:ok, _name} <- required_binary(tool, :name),
         {:ok, _schema} <- required_map(tool, :input_schema) do
      {:ok, tool}
    end
  end

  defp project_one(tool) when is_map(tool) do
    {:error,
     Tool.error(
       :invalid_args,
       "Anthropic provider does not support Provider-hosted tools.",
       %{
         field: :tools,
         unsupported_capability: "provider_hosted_tools",
         tool: safe_tool_label(tool),
         next_action: "omit hosted tools or use an OpenAI Responses provider"
       }
     )}
  end

  defp project_one(tool) do
    {:error,
     Tool.error(:invalid_args, "Anthropic tool specs must be maps.", %{
       field: :tools,
       received: inspect(tool)
     })}
  end

  defp function_tool(tool) do
    with {:ok, name} <- required_binary(tool, :name),
         {:ok, description} <- required_binary(tool, :description),
         {:ok, parameters} <- required_map(tool, :parameters) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "input_schema" => parameters
       }}
    end
  end

  defp required_binary(tool, field) do
    case get_field(tool, field) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error,
         Tool.error(:invalid_args, "Anthropic function tool is missing a required field.", %{
           field: field,
           expected: "non-empty string"
         })}
    end
  end

  defp required_map(tool, field) do
    case get_field(tool, field) do
      value when is_map(value) ->
        {:ok, value}

      _ ->
        {:error,
         Tool.error(:invalid_args, "Anthropic function tool is missing a required field.", %{
           field: field,
           expected: "map"
         })}
    end
  end

  defp get_field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp safe_tool_label(tool) do
    get_field(tool, :type) || get_field(tool, :name) || "unknown"
  end
end
