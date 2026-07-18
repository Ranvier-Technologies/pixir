defmodule Pixir.Delegate.Handle do
  @moduledoc """
  Stable Delegate handle helpers.

  Delegate service mode has two identities:

    * `delegate_id` is the user-facing service handle returned by Delegate surfaces;
    * `parent_session_id` is the durable Pixir Session Log root used for diagnostics,
      tree projection, and restart-safe status.

  The current implementation has no separate durable Delegate index. To keep
  `status`/`attach`/`cancel` useful before a resident owner exists, `delegate_id` is a
  reversible `dlg1_...` wrapper around `parent_session_id`. Future owner-backed service
  mode may move this mapping into a durable index, but it must continue exposing the
  parent Session id instead of hiding Log truth behind an opaque service id.

  Bare and decoded parent Session ids use `Pixir.SessionId` exactly as supplied. This
  boundary never trims or otherwise normalizes an invalid id before validation.
  """

  alias Pixir.SessionId

  @prefix "dlg1_"
  @version 1

  @doc "Build a versioned Delegate handle from a parent Session id."
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def build(parent_session_id, opts \\ [])

  def build(parent_session_id, _opts) do
    with :ok <- SessionId.validate(parent_session_id) do
      {:ok,
       %{
         "delegate_id" => encode_parent_session_id(parent_session_id),
         "parent_session_id" => parent_session_id,
         "handle_version" => @version
       }}
    end
  end

  @doc """
  Resolve either a Delegate id or a parent Session id into the stable handle shape.

  Bare Session ids remain accepted for compatibility with the existing attached runner
  and diagnostics commands. A future durable Delegate index can replace the reversible
  encoding without changing callers that already inspect `parent_session_id`.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def resolve(handle_or_session_id, opts \\ [])

  def resolve(handle_or_session_id, _opts) when is_binary(handle_or_session_id) do
    case handle_or_session_id do
      <<"dlg1_", _encoded::binary>> ->
        resolve_delegate_id(handle_or_session_id)

      _bare_session_id ->
        with {:ok, handle} <- build(handle_or_session_id) do
          {:ok, Map.put(handle, "input_kind", "parent_session_id")}
        end
    end
  end

  def resolve(handle_or_session_id, _opts), do: build(handle_or_session_id)

  defp resolve_delegate_id(delegate_id) do
    encoded = String.replace_prefix(delegate_id, @prefix, "")

    with {:ok, parent_session_id} <- decode_parent_session_id(encoded),
         {:ok, handle} <- build(parent_session_id) do
      {:ok, handle |> Map.put("delegate_id", delegate_id) |> Map.put("input_kind", "delegate_id")}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp encode_parent_session_id(parent_session_id) do
    @prefix <> Base.url_encode64(parent_session_id, padding: false)
  end

  defp decode_parent_session_id(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, parent_session_id} when parent_session_id != "" ->
        {:ok, parent_session_id}

      _ ->
        {:error,
         invalid_handle("delegate_id is not a valid Pixir Delegate handle", %{
           "expected_prefix" => @prefix,
           "next_actions" => [
             "use_parent_session_id_from_delegate_output",
             "rerun_delegate_status_with_a_valid_handle"
           ]
         })}
    end
  end

  defp invalid_handle(message, details) do
    %{
      "ok" => false,
      "status" => "rejected",
      "kind" => "invalid_delegate_handle",
      "message" => message,
      "details" => details
    }
  end
end
