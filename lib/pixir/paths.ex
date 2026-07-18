defmodule Pixir.Paths do
  @moduledoc """
  Filesystem conventions for Pixir.

  Two roots (ADR 0002 / 0003):

    * **Global** `~/.pixir/` — cross-project, user-level state: `auth.json`,
      `config.json`. Created lazily, `0700`.
    * **Project** `.pixir/` — per-Workspace state, rooted at the current working
      directory. Sessions live in `.pixir/sessions/<id>.ndjson` and are the
      source of truth for the Log. Session writer leases live under
      `.pixir/session_leases/` and are live-capability evidence, not History.
      Session Resources live next to the Log under `.pixir/sessions/<id>/resources/`.
      This subtree is gitignored.

  Path builders return absolute paths. Content-bearing Log and lease callers use the
  structured state-path helpers below before their filesystem operations. Session
  Resource payload-path hardening is a documented deferred boundary.

  The Workspace root itself is the trusted anchor, including a deliberate symlink alias.
  Below that anchor, Pixir performs `lstat`-based component checks and refuses existing
  or dangling symlinks. This is a static tripwire, not a same-UID race-free guarantee:
  another process may still replace a component between check and use.
  """

  alias Pixir.{SessionId, Tool}

  @global_dirname ".pixir"
  @project_dirname ".pixir"

  @doc "Global root: `~/.pixir` (override with `PIXIR_HOME`)."
  @spec global_root() :: String.t()
  def global_root do
    case System.get_env("PIXIR_HOME") do
      nil -> Path.join(System.user_home!(), @global_dirname)
      home -> Path.expand(home)
    end
  end

  @doc "Project root: `<workspace>/.pixir` (workspace defaults to cwd)."
  @spec project_root(String.t()) :: String.t()
  def project_root(workspace \\ File.cwd!()) do
    Path.join(Path.expand(workspace), @project_dirname)
  end

  @doc "Global `auth.json` path (OAuth credentials)."
  @spec auth_file() :: String.t()
  def auth_file, do: Path.join(global_root(), "auth.json")

  @doc "Global `config.json` path."
  @spec config_file() :: String.t()
  def config_file, do: Path.join(global_root(), "config.json")

  @doc "Pixir-global Skills root: `~/.pixir/skills` (respects `PIXIR_HOME`)."
  @spec global_skills_dir() :: String.t()
  def global_skills_dir, do: Path.join(global_root(), "skills")

  @doc "Project sessions directory: `<workspace>/.pixir/sessions`."
  @spec sessions_dir(String.t()) :: String.t()
  def sessions_dir(workspace \\ File.cwd!()) do
    Path.join(project_root(workspace), "sessions")
  end

  @doc "NDJSON Log path for a given session id."
  @spec session_log(String.t(), String.t()) :: String.t()
  def session_log(session_id, workspace \\ File.cwd!()) do
    Path.join(sessions_dir(workspace), session_id <> ".ndjson")
  end

  @doc "Project Session writer lease directory: `<workspace>/.pixir/session_leases`."
  @spec session_leases_dir(String.t()) :: String.t()
  def session_leases_dir(workspace \\ File.cwd!()) do
    Path.join(project_root(workspace), "session_leases")
  end

  @doc "Writer lease path for a given Session id."
  @spec session_lease(String.t(), String.t()) :: String.t()
  def session_lease(session_id, workspace \\ File.cwd!()) do
    Path.join(session_leases_dir(workspace), session_id <> ".json")
  end

  @doc "Directory for Session writer lease diagnostic records."
  @spec session_lease_releases_dir(String.t()) :: String.t()
  def session_lease_releases_dir(workspace \\ File.cwd!()) do
    Path.join(session_leases_dir(workspace), "releases")
  end

  @doc "Directory for durable Session Resources attached to a Session."
  @spec session_resources_dir(String.t(), String.t()) :: String.t()
  def session_resources_dir(session_id, workspace \\ File.cwd!()) do
    Path.join([sessions_dir(workspace), session_id, "resources"])
  end

  @doc "Ensure the Session Resources dir exists and return it."
  @spec ensure_session_resources_dir(String.t(), String.t()) :: String.t()
  def ensure_session_resources_dir(session_id, workspace \\ File.cwd!()) do
    case SessionId.validate(session_id) do
      :ok -> session_id |> session_resources_dir(workspace) |> ensure_state_dir!(workspace)
      {:error, error} -> raise ArgumentError, error.error.message
    end
  end

  @doc "Ensure the global root exists (mode 0700) and return it."
  @spec ensure_global_root() :: String.t()
  def ensure_global_root do
    root = global_root()
    File.mkdir_p!(root)
    _ = File.chmod(root, 0o700)
    root
  end

  @doc "Ensure the project sessions dir exists and return it."
  @spec ensure_sessions_dir(String.t()) :: String.t()
  def ensure_sessions_dir(workspace \\ File.cwd!()) do
    workspace |> sessions_dir() |> ensure_state_dir!(workspace)
  end

  @doc "Ensure the Session writer lease dir exists and return it."
  @spec ensure_session_leases_dir(String.t()) :: String.t()
  def ensure_session_leases_dir(workspace \\ File.cwd!()) do
    workspace |> session_leases_dir() |> ensure_state_dir!(workspace)
  end

  @doc "Ensure the Session writer lease releases dir exists and return it."
  @spec ensure_session_lease_releases_dir(String.t()) :: String.t()
  def ensure_session_lease_releases_dir(workspace \\ File.cwd!()) do
    workspace |> session_lease_releases_dir() |> ensure_state_dir!(workspace)
  end

  @typedoc "Observed state of the final component of a checked Pixir state path."
  @type state_path_state :: :missing | :regular | :directory | atom()

  @doc """
  Inspect every component below the trusted Workspace root with `File.lstat/1`.

  `:expected` may be `:any`, `:regular`, or `:directory`. Missing paths are reported as
  `state: :missing`; existing symlinks, non-directory ancestors, unexpected final types,
  and lstat failures return structured `:unsafe_state_path` errors without following or
  reading a target.
  """
  @spec inspect_state_path(String.t(), String.t(), keyword()) ::
          {:ok, %{path: String.t(), state: state_path_state()}} | {:error, map()}
  def inspect_state_path(workspace, path, opts \\ [])

  def inspect_state_path(workspace, path, opts)
      when is_binary(workspace) and is_binary(path) and is_list(opts) do
    expected = Keyword.get(opts, :expected, :any)

    with :ok <- validate_expected_type(expected),
         {:ok, root, absolute, components} <- state_location(workspace, path),
         {:ok, state} <- inspect_components(root, components, expected) do
      {:ok, %{path: absolute, state: state}}
    end
  end

  def inspect_state_path(_workspace, _path, _opts),
    do: {:error, unsafe_error("invalid_state_path", nil, nil, nil)}

  @doc "Check a Pixir state path, allowing the final component to be absent."
  @spec preflight_state_path(String.t(), String.t(), keyword()) :: :ok | {:error, map()}
  def preflight_state_path(workspace, path, opts \\ []) do
    case inspect_state_path(workspace, path, opts) do
      {:ok, _status} -> :ok
      {:error, _error} = error -> error
    end
  end

  @doc "Require a checked Pixir state path's final component to be absent."
  @spec preflight_new_state_path(String.t(), String.t()) :: :ok | {:error, map()}
  def preflight_new_state_path(workspace, path) do
    case inspect_state_path(workspace, path) do
      {:ok, %{state: :missing}} ->
        :ok

      {:ok, %{state: state}} ->
        component = Path.relative_to(Path.expand(path), Path.expand(workspace))
        {:error, unsafe_error("state_path_already_exists", component, nil, state)}

      {:error, _error} = error ->
        error
    end
  end

  @doc """
  Create a Pixir-owned directory one component at a time below the trusted Workspace.

  Each existing or newly created component is verified with `lstat`; `mkdir_p` is not
  used, so a pre-existing symlink cannot be followed while creating deeper state.
  """
  @spec ensure_state_dir(String.t(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def ensure_state_dir(workspace, path) when is_binary(workspace) and is_binary(path) do
    with {:ok, root, absolute, components} <- state_location(workspace, path),
         :ok <- ensure_components(root, components, root, 0) do
      {:ok, absolute}
    end
  end

  def ensure_state_dir(_workspace, _path),
    do: {:error, unsafe_error("invalid_state_path", nil, nil, nil)}

  defp validate_expected_type(expected) when expected in [:any, :regular, :directory], do: :ok

  defp validate_expected_type(expected),
    do: {:error, unsafe_error("invalid_expected_type", nil, nil, expected)}

  defp state_location(workspace, path) do
    root = Path.expand(workspace)
    absolute = Path.expand(path)

    cond do
      absolute == root ->
        {:error, unsafe_error("state_path_must_be_below_workspace", nil, nil, nil)}

      not contained?(absolute, root) ->
        {:error, unsafe_error("outside_workspace", nil, nil, nil)}

      true ->
        components = absolute |> Path.relative_to(root) |> Path.split()
        {:ok, root, absolute, components}
    end
  end

  defp inspect_components(root, components, expected),
    do: do_inspect_components(root, components, expected, root, 0)

  defp do_inspect_components(_root, [], _expected, _current, _index),
    do: {:error, unsafe_error("state_path_must_be_below_workspace", nil, nil, nil)}

  defp do_inspect_components(root, [component | rest], expected, current, index) do
    candidate = Path.join(current, component)
    final? = rest == []
    expected_here = if(final?, do: expected, else: :directory)

    case File.lstat(candidate) do
      {:ok, %{type: :symlink}} ->
        {:error,
         unsafe_error("symlink_component", relative_component(candidate, root), index, :symlink)}

      {:ok, %{type: type}} when not final? and type != :directory ->
        {:error,
         unsafe_error(
           "non_directory_component",
           relative_component(candidate, root),
           index,
           type
         )}

      {:ok, %{type: type}} when final? ->
        if expected_type?(type, expected_here) do
          {:ok, type}
        else
          {:error,
           unsafe_error(
             "unexpected_file_type",
             relative_component(candidate, root),
             index,
             type,
             expected_here
           )}
        end

      {:ok, %{type: :directory}} ->
        do_inspect_components(root, rest, expected, candidate, index + 1)

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error,
         unsafe_error(
           "lstat_failed",
           relative_component(candidate, root),
           index,
           nil,
           expected_here,
           reason
         )}
    end
  end

  defp ensure_components(_root, [], _current, _index), do: :ok

  defp ensure_components(root, [component | rest], current, index) do
    candidate = Path.join(current, component)

    with :ok <- ensure_directory_component(root, candidate, index) do
      ensure_components(root, rest, candidate, index + 1)
    end
  end

  defp ensure_directory_component(root, candidate, index) do
    case File.lstat(candidate) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: :symlink}} ->
        {:error,
         unsafe_error("symlink_component", relative_component(candidate, root), index, :symlink)}

      {:ok, %{type: type}} ->
        {:error,
         unsafe_error(
           "non_directory_component",
           relative_component(candidate, root),
           index,
           type,
           :directory
         )}

      {:error, :enoent} ->
        case File.mkdir(candidate) do
          :ok ->
            verify_created_directory(root, candidate, index)

          {:error, :eexist} ->
            ensure_directory_component(root, candidate, index)

          {:error, reason} ->
            {:error,
             unsafe_error(
               "mkdir_failed",
               relative_component(candidate, root),
               index,
               nil,
               :directory,
               reason
             )}
        end

      {:error, reason} ->
        {:error,
         unsafe_error(
           "lstat_failed",
           relative_component(candidate, root),
           index,
           nil,
           :directory,
           reason
         )}
    end
  end

  defp verify_created_directory(root, candidate, index) do
    case File.lstat(candidate) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: type}} ->
        {:error,
         unsafe_error(
           if(type == :symlink, do: "symlink_component", else: "unexpected_file_type"),
           relative_component(candidate, root),
           index,
           type,
           :directory
         )}

      {:error, reason} ->
        {:error,
         unsafe_error(
           "lstat_failed",
           relative_component(candidate, root),
           index,
           nil,
           :directory,
           reason
         )}
    end
  end

  defp expected_type?(_type, :any), do: true
  defp expected_type?(type, expected), do: type == expected

  defp contained?(path, "/"), do: String.starts_with?(path, "/")

  defp contained?(path, root),
    do: path == root or String.starts_with?(path, root <> "/")

  defp relative_component(candidate, root), do: Path.relative_to(candidate, root)

  defp unsafe_error(reason, component, index, actual, expected \\ nil, filesystem_reason \\ nil) do
    details =
      %{
        "reason" => reason,
        "next_actions" => [
          "inspect_pixir_state_path_without_following_symlinks",
          "remove_or_relocate_the_unsafe_component_if_authorized"
        ]
      }
      |> maybe_put("component", component)
      |> maybe_put("component_index", index)
      |> maybe_put("actual_type", type_string(actual))
      |> maybe_put("expected_type", type_string(expected))
      |> maybe_put("filesystem_reason", filesystem_reason && inspect(filesystem_reason))

    Tool.error(:unsafe_state_path, "Pixir state path is unsafe", details)
  end

  defp type_string(nil), do: nil
  defp type_string(type) when is_atom(type), do: Atom.to_string(type)
  defp type_string(type), do: inspect(type)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_state_dir!(path, workspace) do
    case ensure_state_dir(workspace, path) do
      {:ok, ^path} -> path
      {:error, error} -> raise ArgumentError, error.error.message
    end
  end
end
