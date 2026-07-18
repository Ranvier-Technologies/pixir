defmodule PixirMonitor.Projection.UnitIdentity do
  @moduledoc """
  Validates one runtime unit-identity component before logical-id encoding.

  Pixir emits Workflow step and Subagent ids from a delimiter-free safe charset.
  Enforcing that same boundary keeps the Presenter's colon-delimited `logical_id`
  encoding invertible and makes reconstructed or hostile evidence fail closed.
  """

  @safe_component ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_bytes 256

  @doc "Returns the safe identity component or a structured projection error."
  @spec component(term()) :: {:ok, String.t()} | {:error, map()}
  def component(value) when is_binary(value) do
    if byte_size(value) <= @max_bytes and Regex.match?(@safe_component, value) do
      {:ok, value}
    else
      error()
    end
  end

  def component(_value), do: error()

  defp error do
    {:error,
     %{
       kind: "run_unit_identity_invalid",
       message: "Logical unit identity components must use Pixir's safe id charset",
       details: %{}
     }}
  end
end
