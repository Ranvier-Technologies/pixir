defmodule PixirMonitor.WorkspaceSet do
  @moduledoc """
  Read-only source scoping for the frozen two-workspace Workspace Overview.

  Roots remain process-local configuration. Public values expose only operator keys.
  """

  @key_regex ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @max_key_bytes 256

  @type source :: %{required(:key) => String.t(), required(:path) => String.t()}

  @spec configured() :: {:ok, [source()]} | {:error, map()}
  def configured do
    case Application.get_env(:pixir_monitor, :workspace_set) do
      [first, second] = sources ->
        if valid_source?(first) and valid_source?(second) and first.key != second.key,
          do: {:ok, sources},
          else: not_configured()

      _ ->
        not_configured()
    end
  end

  @spec mode() :: {:ok, :single | :workspace_set}
  def mode do
    case configured() do
      {:ok, _sources} -> {:ok, :workspace_set}
      {:error, _error} -> {:ok, :single}
    end
  end

  defp valid_source?(%{key: key, path: path}) when is_binary(key) and is_binary(path),
    do: validate_key(key) == :ok

  defp valid_source?(_source), do: false

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

  defp scope_error(%{kind: "run_not_found"} = error, key),
    do: %{kind: "run_not_found", message: error.message, details: %{workspace: key, run_id: run_id(error)}}

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
