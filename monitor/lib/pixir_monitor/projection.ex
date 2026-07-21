defmodule PixirMonitor.Projection do
  @moduledoc """
  Recomputes the renderer-neutral `pixir.presenter.run.v1` read model.

  The adapter folds canonical parent and child events, then overlays volatile facts
  only onto liveness. It never stores a projection. Input may be a complete portable
  fixture or its `inputs` map; complete fixtures additionally provide deterministic
  fixture identity and evidence-boundary metadata.
  """

  alias PixirMonitor.Projection.{Builder, Validator}

  @type error :: %{required(:kind) => String.t(), required(:message) => String.t(), optional(:details) => map()}

  @doc "Projects one fixture-shaped input and validates the completed map fail-closed."
  @spec project(map()) :: {:ok, map()} | {:error, error()}
  def project(value) when is_map(value) do
    with {:ok, projection} <- Builder.build(value),
         :ok <- Validator.validate(projection) do
      {:ok, projection}
    end
  rescue
    # Projection failures cross the API boundary, and their messages can carry
    # filesystem paths or URLs. Report a fixed atom instead of Exception.message/1.
    _exception ->
      {:error,
       %{
         kind: "projection_failed",
         message: "Presenter projection could not be built",
         details: %{exception: :projection_raised}
       }}
  end

  def project(_value),
    do:
      {:error,
       %{
         kind: "invalid_projection_input",
         message: "Projection input must be a map",
         details: %{}
       }}
end
