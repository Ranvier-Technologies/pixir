defmodule Pixir.Provider.ToolCall do
  @moduledoc """
  Cross-provider validation for Provider-declared finalized tool calls.

  A call is executable only after its Provider completion boundary and only when its
  identity is bounded and its arguments are a JSON object. Invalid identity values are
  never echoed in structured errors.
  """

  alias Pixir.Tool

  @identity_re ~r/\A[A-Za-z0-9_.:-]+\z/

  @doc "Validate a finalized call whose arguments are still encoded JSON."
  @spec from_json(term(), term(), term()) :: {:ok, map()} | {:error, map()}
  def from_json(call_id, name, arguments) do
    with :ok <- validate_identity(:call_id, call_id, 160),
         :ok <- validate_identity(:name, name, 64),
         {:ok, args} <- decode_object(arguments) do
      {:ok, %{call_id: call_id, name: name, args: args}}
    end
  end

  @doc "Validate a finalized call whose arguments are already decoded."
  @spec from_map(term(), term(), term()) :: {:ok, map()} | {:error, map()}
  def from_map(call_id, name, arguments) do
    with :ok <- validate_identity(:call_id, call_id, 160),
         :ok <- validate_identity(:name, name, 64),
         true <- is_map(arguments) and not is_struct(arguments) do
      {:ok, %{call_id: call_id, name: name, args: arguments}}
    else
      false -> {:error, invalid_arguments(:non_object)}
      {:error, _} = error -> error
    end
  end

  defp decode_object(arguments) when is_binary(arguments) and byte_size(arguments) > 0 do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) and not is_struct(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, invalid_arguments(:non_object)}
      {:error, _error} -> {:error, invalid_arguments(:invalid_json)}
    end
  end

  defp decode_object(_arguments), do: {:error, invalid_arguments(:missing_json_object)}

  defp validate_identity(field, value, max) when is_binary(value) do
    bytes = byte_size(value)

    if String.valid?(value) and bytes in 1..max and Regex.match?(@identity_re, value) do
      :ok
    else
      {:error,
       Tool.error(:invalid_response, "Provider tool-call identity was invalid.", %{
         field: field,
         observed_bytes: bytes
       })}
    end
  end

  defp validate_identity(field, _value, _max) do
    {:error,
     Tool.error(:invalid_response, "Provider tool-call identity was invalid.", %{
       field: field,
       observed_bytes: nil
     })}
  end

  defp invalid_arguments(reason) do
    Tool.error(:invalid_response, "Provider tool-call arguments must be a JSON object.", %{
      field: :arguments,
      reason: reason
    })
  end
end
