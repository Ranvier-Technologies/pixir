defmodule PixirMonitor.WorkspaceSet do
  @moduledoc """
  Read-only source scoping for the bounded-N Workspace Overview.

  The set holds between `min_sources/0` and `max_sources/0` explicitly declared
  sources. The bound is a real bound: a configured list outside it is not
  valid configuration, never a truncation or a silent fallback to single mode.

  Roots remain process-local configuration. Public values expose only operator keys.
  """

  @key_regex ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_key_bytes 256
  @min_sources 2
  @max_sources 8

  @type source :: %{required(:key) => String.t(), required(:path) => String.t()}

  @doc "Smallest declared set size that enters workspace-set mode."
  @spec min_sources() :: pos_integer()
  def min_sources, do: @min_sources

  @doc "Largest declared set size workspace-set mode accepts."
  @spec max_sources() :: pos_integer()
  def max_sources, do: @max_sources

  @spec configured() :: {:ok, [source()]} | {:error, map()}
  def configured do
    case Application.fetch_env(:pixir_monitor, :workspace_set) do
      :error -> not_configured()
      {:ok, sources} -> validate_sources(sources)
    end
  end

  defp validate_sources(sources) do
    case source_count(sources, 0) do
      :malformed ->
        invalid_configuration("malformed_source")

      count when count < @min_sources or count > @max_sources ->
        invalid_configuration("cardinality_out_of_range")

      _ ->
        cond do
          not Enum.all?(sources, &source_shape?/1) -> invalid_configuration("malformed_source")
          not Enum.all?(sources, &valid_key?(&1.key)) -> invalid_configuration("invalid_key")
          not unique_keys?(sources) -> invalid_configuration("duplicate_key")
          true -> {:ok, sources}
        end
    end
  end

  defp source_count([], count), do: count
  defp source_count([_ | _], count) when count >= @max_sources, do: @max_sources + 1
  defp source_count([_ | rest], count), do: source_count(rest, count + 1)
  defp source_count(_, _), do: :malformed

  defp source_shape?(%{key: _, path: path}) when is_binary(path), do: String.trim(path) != ""
  defp source_shape?(_), do: false

  defp invalid_configuration(reason),
    do: {:error, %{kind: "workspace_set_configuration_invalid", message: "Workspace set configuration is invalid", details: %{reason: reason}}}

  defp unique_keys?(sources) do
    keys = Enum.map(sources, & &1.key)
    length(Enum.uniq(keys)) == length(keys)
  end

  @spec mode() :: {:ok, :single | :workspace_set} | {:error, map()}
  def mode do
    case configured() do
      {:ok, _sources} -> {:ok, :workspace_set}
      {:error, %{kind: "workspace_set_not_configured"}} -> {:ok, :single}
      {:error, _} = error -> error
    end
  end

  defp not_configured,
    do: {:error, %{kind: "workspace_set_not_configured", message: "Workspace set is not configured"}}

  @spec validate_key(term()) :: :ok | {:error, map()}
  def validate_key(key) do
    if valid_key?(key),
      do: :ok,
      else: {:error, %{kind: "invalid_workspace_key", message: "Workspace key is invalid"}}
  end

  defp valid_key?(key) when is_binary(key),
    do: byte_size(key) in 1..@max_key_bytes and Regex.match?(@key_regex, key)

  defp valid_key?(_key), do: false

  @spec source(String.t()) :: {:ok, source()} | {:error, map()}
  def source(key) when is_binary(key) do
    with :ok <- validate_key(key),
         {:ok, sources} <- configured(),
         %{} = source <- Enum.find(sources, &(&1.key == key)) do
      {:ok, source}
    else
      {:error, %{kind: "invalid_workspace_key"}} = error -> error
      nil -> {:error, %{kind: "workspace_not_found", message: "Workspace was not declared", details: %{workspace: key}}}
      {:error, _} = error -> error
    end
  end

  @spec sessions_directory(source()) :: {:ok, String.t()} | {:error, map()}
  def sessions_directory(%{path: root}) do
    directory = Path.join([root, ".pixir", "sessions"])

    case File.lstat(directory) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, "observed"}
      {:error, :enoent} -> {:ok, "absent"}
      {:ok, _} -> {:error, %{kind: "workspace_unavailable", message: "Workspace sessions directory is unavailable"}}
      {:error, reason} -> {:error, %{kind: "workspace_unavailable", message: "Workspace sessions directory is unavailable", details: %{reason: safe_error_kind(reason)}}}
    end
  end

  @spec list_runs(String.t()) :: {:ok, map()} | {:error, map()}
  def list_runs(key), do: scoped_call(key, :list_runs, [])

  @spec fetch_run(String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def fetch_run(key, id), do: scoped_call(key, :fetch_run, [id])

  defp scoped_call(key, function, args) do
    with {:ok, source} <- source(key),
         {:ok, provenance} <- sessions_directory(source),
         {:ok, snapshot} <- call_source(source, function, args) do
      {:ok, %{"workspace" => key, "source" => %{"sessions_directory" => provenance}, "snapshot" => snapshot}}
    else
      {:error, error} -> {:error, scope_error(error, key)}
    end
  end

  defp call_source(source, function, args) do
    implementation = Application.get_env(:pixir_monitor, :run_source, PixirMonitor.Projection.Source)

    cond do
      implementation == PixirMonitor.Projection.Source ->
        apply(implementation, function, args ++ [source_options(source)])

      function_exported?(implementation, function, length(args) + 1) ->
        apply(implementation, function, args ++ [source])

      true ->
        apply(implementation, function, args)
    end
  rescue
    _ -> {:error, %{kind: "workspace_unavailable", message: "Workspace projection is unavailable"}}
  catch
    _, _ -> {:error, %{kind: "workspace_unavailable", message: "Workspace projection is unavailable"}}
  end

  defp source_options(%{path: path}) do
    Application.get_env(:pixir_monitor, :projection_source, [])
    |> Keyword.put(:workspace, path)
  end

  defp scope_error(%{kind: "run_not_found"} = error, key) do
    details = %{workspace: key, run_id: run_id(error)}
    details = put_optional_session_id(details, :parent_session_id, parent_session_id(error))
    details = put_optional_reason(details, :parent_unprojected_reason, parent_unprojected_reason(error))
    %{kind: "run_not_found", message: error.message, details: details}
  end

  defp scope_error(%{kind: "invalid_run_id"} = error, key),
    do: %{kind: "invalid_run_id", message: error.message, details: invalid_id_details(error, key)}

  defp scope_error(%{kind: "invalid_workspace_key", message: message}, _key),
    do: %{kind: "invalid_workspace_key", message: message}

  defp scope_error(%{kind: "workspace_not_found", message: message}, key),
    do: %{kind: "workspace_not_found", message: message, details: %{workspace: key}}

  defp scope_error(error, key) when is_map(error) do
    reason = error |> Map.get(:details, %{}) |> Map.get(:reason)
    details = %{workspace: key}
    details = if is_nil(reason), do: details, else: Map.put(details, :reason, safe_error_kind(reason))
    %{kind: "workspace_unavailable", message: "Workspace projection is unavailable", details: details}
  end

  defp scope_error(_error, key),
    do: %{kind: "workspace_unavailable", message: "Workspace projection is unavailable", details: %{workspace: key}}

  defp run_id(error), do: get_in(error, [:details, :run_id]) || get_in(error, [:details, "run_id"]) || "unknown"

  defp parent_session_id(error),
    do: get_in(error, [:details, :parent_session_id]) || get_in(error, [:details, "parent_session_id"])

  defp parent_unprojected_reason(error),
    do: get_in(error, [:details, :parent_unprojected_reason]) || get_in(error, [:details, "parent_unprojected_reason"])

  defp put_optional_session_id(details, key, value) do
    if is_binary(value) and Pixir.SessionId.valid?(value), do: Map.put(details, key, value), else: details
  end

  defp put_optional_reason(details, key, value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value),
      do: Map.put(details, key, value),
      else: details
  end

  defp invalid_id_details(error, key) do
    max_bytes = get_in(error, [:details, :max_bytes]) || get_in(error, [:details, "max_bytes"])
    if is_integer(max_bytes), do: %{workspace: key, max_bytes: max_bytes}, else: %{workspace: key}
  end

  defp safe_error_kind(value) when is_atom(value), do: value |> Atom.to_string() |> safe_error_kind()

  defp safe_error_kind(value) when is_binary(value) do
    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value), do: value, else: "workspace_error"
  end

  defp safe_error_kind(_value), do: "workspace_error"
end
