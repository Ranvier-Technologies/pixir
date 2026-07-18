defmodule Pixir.Provider.OpenResponsesSchema do
  @moduledoc """
  Total, bounded validator for the pinned Open Responses HTTP/SSE event profile.

  Schemas are compiled into `OpenResponsesSchema.Generated`; validation never reads a
  file, resolves an external reference, parses a schema, or performs network I/O at
  runtime. Each schema/instance evaluation consumes the frozen event budget, including
  union branches. Draft 2020-12 integer semantics include decoded integral floats such
  as `1.0` and `-0.0`; local policy may constrain their value after schema validation.
  Diagnostics are fixed atoms and never retain Provider values.
  """

  alias Pixir.Provider.OpenResponsesSchema.Generated

  @max_depth 64
  @max_evaluations 250_000

  @typedoc "A fixed validation failure safe for Provider diagnostics."
  @type reason :: :invalid_event_shape | :validation_budget_exceeded

  @doc "Validate one decoded known event against its generated pinned root schema."
  @spec validate(String.t(), term()) :: :ok | {:error, reason()}
  def validate(type, event) when is_binary(type) do
    with {:ok, root} <- Generated.event_root(type),
         {:ok, schema} <- Generated.schema(root) do
      case evaluate(schema, event, 0, @max_evaluations) do
        {:ok, _remaining} -> :ok
        {:invalid, _remaining} -> {:error, :invalid_event_shape}
        :budget_exceeded -> {:error, :validation_budget_exceeded}
      end
    else
      _other -> {:error, :invalid_event_shape}
    end
  rescue
    _error -> {:error, :invalid_event_shape}
  catch
    _kind, _reason -> {:error, :invalid_event_shape}
  end

  def validate(_type, _event), do: {:error, :invalid_event_shape}

  defp evaluate(_schema, _value, depth, _remaining) when depth > @max_depth,
    do: :budget_exceeded

  defp evaluate(_schema, _value, _depth, remaining) when remaining <= 0,
    do: :budget_exceeded

  defp evaluate(schema, value, depth, remaining) when is_map(schema) do
    remaining = remaining - 1

    with {:ok, remaining} <- validate_ref(schema, value, depth, remaining),
         {:ok, remaining} <- validate_type(schema, value, remaining),
         {:ok, remaining} <- validate_enum(schema, value, remaining),
         {:ok, remaining} <- validate_object(schema, value, depth, remaining),
         {:ok, remaining} <- validate_items(schema, value, depth, remaining),
         {:ok, remaining} <- validate_all_of(schema, value, depth, remaining),
         {:ok, remaining} <- validate_one_of(schema, value, depth, remaining),
         {:ok, remaining} <- validate_any_of(schema, value, depth, remaining) do
      {:ok, remaining}
    end
  end

  defp evaluate(_schema, _value, _depth, remaining), do: {:invalid, remaining}

  defp validate_ref(%{"$ref" => name}, value, depth, remaining) do
    case Generated.schema(name) do
      {:ok, schema} -> normalize(evaluate(schema, value, depth + 1, remaining))
      :error -> {:invalid, remaining}
    end
  end

  defp validate_ref(_schema, _value, _depth, remaining), do: {:ok, remaining}

  defp validate_type(%{"type" => type}, value, remaining) do
    if exact_type?(type, value), do: {:ok, remaining}, else: {:invalid, remaining}
  end

  defp validate_type(_schema, _value, remaining), do: {:ok, remaining}

  defp exact_type?("object", value), do: is_map(value) and not is_struct(value)
  defp exact_type?("array", value), do: is_list(value)
  defp exact_type?("string", value), do: is_binary(value)
  defp exact_type?("integer", value), do: json_integer?(value)
  defp exact_type?("number", value), do: is_number(value)
  defp exact_type?("boolean", value), do: is_boolean(value)
  defp exact_type?("null", value), do: is_nil(value)
  defp exact_type?(_type, _value), do: false

  defp json_integer?(value) when is_integer(value), do: true
  defp json_integer?(value) when is_float(value), do: value == Float.floor(value)
  defp json_integer?(_value), do: false

  defp validate_enum(%{"enum" => allowed}, value, remaining) when is_list(allowed) do
    if Enum.any?(allowed, &json_equal?(&1, value)),
      do: {:ok, remaining},
      else: {:invalid, remaining}
  end

  defp validate_enum(_schema, _value, remaining), do: {:ok, remaining}

  defp json_equal?(left, right) when is_number(left) and is_number(right), do: left == right
  defp json_equal?(left, right), do: left === right

  defp validate_object(schema, value, depth, remaining)
       when is_map(value) and not is_struct(value) do
    required = Map.get(schema, "required", [])
    properties = Map.get(schema, "properties", %{})

    if Enum.all?(required, &Map.has_key?(value, &1)) do
      with {:ok, remaining} <- validate_properties(properties, value, depth, remaining),
           {:ok, remaining} <-
             validate_additional_properties(schema, properties, value, depth, remaining) do
        {:ok, remaining}
      end
    else
      {:invalid, remaining}
    end
  end

  defp validate_object(schema, _value, _depth, remaining) do
    if Map.has_key?(schema, "required") or Map.has_key?(schema, "properties") do
      {:invalid, remaining}
    else
      {:ok, remaining}
    end
  end

  defp validate_properties(properties, value, depth, remaining) when is_map(properties) do
    Enum.reduce_while(properties, {:ok, remaining}, fn {name, schema}, {:ok, budget} ->
      if Map.has_key?(value, name) do
        case evaluate(schema, Map.fetch!(value, name), depth + 1, budget) do
          {:ok, next} -> {:cont, {:ok, next}}
          other -> {:halt, normalize(other)}
        end
      else
        {:cont, {:ok, budget}}
      end
    end)
  end

  defp validate_properties(_properties, _value, _depth, remaining),
    do: {:invalid, remaining}

  defp validate_additional_properties(schema, properties, value, depth, remaining) do
    extras = Map.drop(value, Map.keys(properties))

    case Map.get(schema, "additionalProperties", :allowed) do
      :allowed ->
        {:ok, remaining}

      true ->
        {:ok, remaining}

      false ->
        if map_size(extras) == 0, do: {:ok, remaining}, else: {:invalid, remaining}

      additional_schema when is_map(additional_schema) ->
        Enum.reduce_while(extras, {:ok, remaining}, fn {_name, extra}, {:ok, budget} ->
          case evaluate(additional_schema, extra, depth + 1, budget) do
            {:ok, next} -> {:cont, {:ok, next}}
            other -> {:halt, normalize(other)}
          end
        end)

      _other ->
        {:invalid, remaining}
    end
  end

  defp validate_items(%{"items" => item_schema}, value, depth, remaining)
       when is_list(value) and is_map(item_schema) do
    Enum.reduce_while(value, {:ok, remaining}, fn item, {:ok, budget} ->
      case evaluate(item_schema, item, depth + 1, budget) do
        {:ok, next} -> {:cont, {:ok, next}}
        other -> {:halt, normalize(other)}
      end
    end)
  end

  defp validate_items(%{"items" => _item_schema}, _value, _depth, remaining),
    do: {:invalid, remaining}

  defp validate_items(_schema, _value, _depth, remaining), do: {:ok, remaining}

  defp validate_all_of(%{"allOf" => branches}, value, depth, remaining)
       when is_list(branches) do
    Enum.reduce_while(branches, {:ok, remaining}, fn branch, {:ok, budget} ->
      case evaluate(branch, value, depth + 1, budget) do
        {:ok, next} -> {:cont, {:ok, next}}
        other -> {:halt, normalize(other)}
      end
    end)
  end

  defp validate_all_of(_schema, _value, _depth, remaining), do: {:ok, remaining}

  defp validate_one_of(%{"oneOf" => branches} = schema, value, depth, remaining)
       when is_list(branches) do
    case discriminator_branch(schema, value, branches) do
      {:ok, branch} ->
        normalize(evaluate(branch, value, depth + 1, remaining))

      :fallback ->
        validate_exactly_one(branches, value, depth, remaining)
    end
  end

  defp validate_one_of(_schema, _value, _depth, remaining), do: {:ok, remaining}

  defp discriminator_branch(
         %{
           "x-pixir-discriminator" => %{"property" => property, "index" => index}
         },
         value,
         branches
       )
       when is_map(value) and not is_struct(value) and is_map(index) do
    with literal when is_binary(literal) <- Map.get(value, property),
         branch_index when is_integer(branch_index) <- Map.get(index, literal),
         branch when is_map(branch) <- Enum.at(branches, branch_index) do
      {:ok, branch}
    else
      _other -> :fallback
    end
  end

  defp discriminator_branch(_schema, _value, _branches), do: :fallback

  defp validate_exactly_one(branches, value, depth, remaining) do
    Enum.reduce_while(branches, {:ok, remaining, 0}, fn branch, {:ok, budget, successes} ->
      case evaluate(branch, value, depth + 1, budget) do
        {:ok, next} -> {:cont, {:ok, next, successes + 1}}
        {:invalid, next} -> {:cont, {:ok, next, successes}}
        :budget_exceeded -> {:halt, :budget_exceeded}
      end
    end)
    |> case do
      {:ok, budget, 1} -> {:ok, budget}
      {:ok, budget, _count} -> {:invalid, budget}
      :budget_exceeded -> :budget_exceeded
    end
  end

  defp validate_any_of(%{"anyOf" => branches}, value, depth, remaining)
       when is_list(branches) do
    validate_at_least_one(branches, value, depth, remaining)
  end

  defp validate_any_of(_schema, _value, _depth, remaining), do: {:ok, remaining}

  defp validate_at_least_one([], _value, _depth, remaining), do: {:invalid, remaining}

  defp validate_at_least_one([branch | rest], value, depth, remaining) do
    case evaluate(branch, value, depth + 1, remaining) do
      {:ok, next} -> {:ok, next}
      {:invalid, next} -> validate_at_least_one(rest, value, depth, next)
      :budget_exceeded -> :budget_exceeded
    end
  end

  defp normalize({:ok, remaining}), do: {:ok, remaining}
  defp normalize({:invalid, remaining}), do: {:invalid, remaining}
  defp normalize(:budget_exceeded), do: :budget_exceeded
end
