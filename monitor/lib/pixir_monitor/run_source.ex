defmodule PixirMonitor.RunSource do
  @moduledoc """
  Renderer-neutral facade for recomputable, authoritative run projections.

  Implementations must not persist a presenter store. Public calls normalize failures
  to structured `{:error, term}` results.
  """

  @type error :: %{required(:kind) => String.t(), required(:message) => String.t(), optional(:details) => map()}
  @callback list_runs() :: {:ok, term()} | {:error, term()}
  @callback fetch_run(String.t()) :: {:ok, term()} | {:error, term()}

  @spec list_runs() :: {:ok, term()} | {:error, error()}
  def list_runs, do: call(:list_runs, [])

  @spec fetch_run(String.t()) :: {:ok, term()} | {:error, error()}
  def fetch_run(id) when is_binary(id), do: call(:fetch_run, [id])

  defp call(function, args) do
    implementation = Application.get_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)

    case apply(implementation, function, args) do
      {:ok, value} -> {:ok, value}
      {:error, %{kind: _, message: _} = error} -> {:error, error}
      {:error, reason} -> {:error, structured(reason)}
      other -> {:error, structured({:invalid_return, other})}
    end
  rescue
    # Raised source failures cross the API boundary, and their messages can carry
    # filesystem paths or URLs. Report a fixed atom instead of Exception.message/1.
    _exception ->
      {:error, %{kind: "run_source_failed", message: "Run source failed", details: %{exception: :run_source_raised}}}
  catch
    # Thrown and exited source terms cross the same API boundary and can carry
    # filesystem paths or URLs. Report fixed atoms instead of inspecting the terms.
    :throw, _reason ->
      {:error, %{kind: "run_source_failed", message: "Run source failed", details: %{reason: :run_source_thrown}}}

    :exit, _reason ->
      {:error, %{kind: "run_source_failed", message: "Run source failed", details: %{reason: :run_source_exited}}}
  end

  defp structured(reason) do
    %{kind: "run_source_failed", message: "Run source could not provide the requested projection", details: %{reason: inspect(reason, limit: 20, printable_limit: 200)}}
  end
end

defmodule PixirMonitor.RunSource.Empty do
  @moduledoc "No-state startup source used until the normative projection adapter is configured."
  @behaviour PixirMonitor.RunSource

  @impl true
  def list_runs, do: {:ok, []}

  @impl true
  def fetch_run(_id), do: {:error, %{kind: "run_not_found", message: "Run was not found", details: %{}}}
end
