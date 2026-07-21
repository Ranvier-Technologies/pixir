defmodule PixirMonitor.Projection.Validator do
  @moduledoc """
  Fail-closed Draft 2020-12 validation for Presenter Projection v1.

  The vendored schema bytes are embedded from an external resource at compile time so
  source runs and the standalone escript validate against the same contract without a
  runtime filesystem dependency. JSV's compiled value is derived validation machinery
  only; this module never caches or persists run truth.
  """

  @schema_path Path.expand("../../../priv/presenter/schema/pixir.presenter.run.v1.schema.json", __DIR__)
  @external_resource @schema_path
  @schema_bytes File.read!(@schema_path)

  @doc "Validates a completed projection with the vendored JSV schema."
  @spec validate(map()) :: :ok | {:error, map()}
  def validate(projection) when is_map(projection) do
    with {:ok, schema} <- load_schema(),
         {:ok, compiled} <- compile(schema) do
      case JSV.validate(projection, compiled, cast: false) do
        {:ok, _value} -> :ok
        {:error, reason} -> schema_error(reason)
      end
    end
  rescue
    # Validator failures can flow into API diagnostics, and their messages can carry
    # filesystem paths or URLs. Report a fixed atom instead of Exception.message/1.
    _exception ->
      {:error,
       %{
         kind: "projection_schema_validation_failed",
         message: "Presenter projection failed schema validation",
         details: %{exception: :projection_schema_validation_raised}
       }}
  end

  def validate(_),
    do:
      {:error,
       %{
         kind: "projection_schema_validation_failed",
         message: "Presenter projection must be a map",
         details: %{}
       }}

  defp load_schema do
    with {:ok, schema} <- Jason.decode(@schema_bytes) do
      {:ok, schema}
    else
      {:error, reason} ->
        {:error,
         %{
           kind: "projection_schema_unavailable",
           message: "Vendored Presenter schema could not be loaded",
           details: %{reason: inspect(reason)}
         }}
    end
  end

  defp compile(schema) do
    case JSV.build(schema, formats: true, atoms: false, warnings: :silent) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, reason} -> schema_error(reason)
    end
  end

  defp schema_error(reason) do
    {:error,
     %{
       kind: "projection_schema_validation_failed",
       message: "Presenter projection failed schema validation",
       details: %{errors: inspect(reason, limit: 50, printable_limit: 4_096)}
     }}
  end
end
