defmodule Pixir.Support.ToolContract do
  @moduledoc """
  Shared assertions enforcing the ADR 0005 ergonomics contract on every Tool. Each
  tool test calls `verify!/3` so the contract can't silently regress as tools are
  added: a well-formed `__tool__/0` spec, both `execute/2` and `dry_run/2` exported,
  and a `dry_run/2` that returns a plan map (no side effects) for valid sample args.
  """

  import ExUnit.Assertions

  @doc "Assert `module` satisfies the Tool ergonomics contract for `sample_args`."
  @spec verify!(module(), map(), map()) :: :ok
  def verify!(module, sample_args, context) do
    spec = module.__tool__()

    assert is_binary(spec.name) and spec.name != "",
           "#{inspect(module)}: __tool__.name must be a non-empty string"

    assert is_binary(spec.description) and spec.description != "",
           "#{inspect(module)}: __tool__.description must be non-empty"

    assert match?(%{"type" => "object"}, spec.parameters),
           "#{inspect(module)}: parameters must be a JSON object schema"

    assert_array_items!(module, spec.parameters)

    assert function_exported?(module, :execute, 2), "#{inspect(module)}: must export execute/2"

    assert function_exported?(module, :dry_run, 2),
           "#{inspect(module)}: must export dry_run/2 (ADR 0005)"

    assert {:ok, plan} = module.dry_run(sample_args, Map.put(context, :dry_run, true)),
           "#{inspect(module)}: dry_run/2 must return {:ok, plan} for valid args"

    assert is_map(plan), "#{inspect(module)}: dry_run plan must be a map"
    :ok
  end

  defp assert_array_items!(module, %{"type" => "array"} = schema) do
    assert Map.has_key?(schema, "items"),
           "#{inspect(module)}: array schemas must declare items for strict tool schemas"

    assert_array_items!(module, schema["items"])
  end

  defp assert_array_items!(module, %{"properties" => properties} = schema)
       when is_map(properties) do
    Enum.each(properties, &assert_array_items!(module, elem(&1, 1)))
    maybe_assert_items(module, schema)
  end

  defp assert_array_items!(module, schema) when is_map(schema),
    do: maybe_assert_items(module, schema)

  defp assert_array_items!(_module, _schema), do: :ok

  defp maybe_assert_items(module, %{"items" => items}), do: assert_array_items!(module, items)
  defp maybe_assert_items(_module, _schema), do: :ok
end
