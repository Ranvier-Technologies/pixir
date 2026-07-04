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

  All helpers return absolute paths. `ensure_*` variants create the directory
  (idempotently) before returning it.
  """

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
    dir = session_resources_dir(session_id, workspace)
    File.mkdir_p!(dir)
    dir
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
    dir = sessions_dir(workspace)
    File.mkdir_p!(dir)
    dir
  end

  @doc "Ensure the Session writer lease dir exists and return it."
  @spec ensure_session_leases_dir(String.t()) :: String.t()
  def ensure_session_leases_dir(workspace \\ File.cwd!()) do
    dir = session_leases_dir(workspace)
    File.mkdir_p!(dir)
    dir
  end

  @doc "Ensure the Session writer lease releases dir exists and return it."
  @spec ensure_session_lease_releases_dir(String.t()) :: String.t()
  def ensure_session_lease_releases_dir(workspace \\ File.cwd!()) do
    dir = session_lease_releases_dir(workspace)
    File.mkdir_p!(dir)
    dir
  end
end
