defmodule Pixir.PathsTest do
  use ExUnit.Case, async: true

  alias Pixir.Paths

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-paths-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, outside: outside}
  end

  test "creates Pixir state directories one checked component at a time", %{workspace: ws} do
    sessions = Paths.sessions_dir(ws)

    assert {:ok, ^sessions} = Paths.ensure_state_dir(ws, sessions)
    assert File.dir?(sessions)
    assert File.read!(Path.join(Paths.project_root(ws), ".gitignore")) == "*\n"
  end

  test "preserves an existing project .gitignore", %{workspace: ws} do
    File.mkdir_p!(Paths.project_root(ws))
    gitignore = Path.join(Paths.project_root(ws), ".gitignore")
    File.write!(gitignore, "sessions/\n!sessions/keep.ndjson\n")

    assert {:ok, _sessions} = Paths.ensure_state_dir(ws, Paths.sessions_dir(ws))
    assert File.read!(gitignore) == "sessions/\n!sessions/keep.ndjson\n"
  end

  test "a project .gitignore creation failure does not block state creation", %{workspace: ws} do
    File.mkdir_p!(Path.join(Paths.project_root(ws), ".gitignore"))

    assert {:ok, sessions} = Paths.ensure_state_dir(ws, Paths.sessions_dir(ws))
    assert File.dir?(sessions)
    assert File.dir?(Path.join(Paths.project_root(ws), ".gitignore"))
  end

  test "project .gitignore excludes Session state from git", %{workspace: ws} do
    assert {_, 0} = System.cmd("git", ["init", "--quiet"], cd: ws, stderr_to_stdout: true)
    assert {:ok, sessions} = Paths.ensure_state_dir(ws, Paths.sessions_dir(ws))
    ignored = Path.join(sessions, "example.ndjson")
    File.write!(ignored, "{}\n")

    assert {output, 0} =
             System.cmd("git", ["check-ignore", ".pixir/sessions/example.ndjson"],
               cd: ws,
               stderr_to_stdout: true
             )

    assert output == ".pixir/sessions/example.ndjson\n"
  end

  test "nested isolated workspace keeps its own project gitignore", %{
    workspace: parent
  } do
    assert {_, 0} = System.cmd("git", ["init", "--quiet"], cd: parent, stderr_to_stdout: true)

    child_workspace =
      Path.join([parent, ".pixir", "subagents", "child-123", "workspace"])

    File.mkdir_p!(child_workspace)
    child_log = Paths.session_log("child-session", child_workspace)

    assert {:ok, _sessions} =
             Paths.ensure_state_dir(child_workspace, Paths.sessions_dir(child_workspace))

    child_gitignore = Path.join(Paths.project_root(child_workspace), ".gitignore")
    assert File.read!(child_gitignore) == "*\n"

    File.write!(child_log, "{}\n")
    relative_log = Path.relative_to(child_log, parent)

    assert {output, 0} =
             System.cmd("git", ["check-ignore", relative_log],
               cd: parent,
               stderr_to_stdout: true
             )

    assert output == relative_log <> "\n"
  end

  test "trusts a deliberate symlink alias used as the Workspace root", %{
    root: root,
    workspace: real
  } do
    alias_path = Path.join(root, "workspace-alias")
    File.ln_s!(real, alias_path)
    sessions = Paths.sessions_dir(alias_path)

    assert {:ok, ^sessions} = Paths.ensure_state_dir(alias_path, sessions)
    assert File.dir?(Path.join(real, ".pixir/sessions"))
  end

  test "rejects a symlinked .pixir ancestor without reading its target", %{
    workspace: ws,
    outside: outside
  } do
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "outside-secret")
    File.ln_s!(outside, Paths.project_root(ws))

    assert {:error,
            %{error: %{kind: :unsafe_state_path, details: %{"component" => ".pixir"}}} =
              error} =
             Paths.inspect_state_path(ws, Paths.session_log("safe", ws), expected: :regular)

    refute inspect(error) =~ "outside-secret"
    assert File.read!(sentinel) == "outside-secret"
  end

  test "rejects symlinked and dangling sessions components", %{workspace: ws, outside: outside} do
    File.mkdir_p!(Paths.project_root(ws))
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "unchanged")
    File.ln_s!(outside, Paths.sessions_dir(ws))

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             Paths.inspect_state_path(ws, Paths.session_log("safe", ws), expected: :regular)

    File.rm!(Paths.sessions_dir(ws))
    File.ln_s!(Path.join(outside, "missing"), Paths.sessions_dir(ws))

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             Paths.inspect_state_path(ws, Paths.session_log("safe", ws), expected: :regular)

    assert File.read!(sentinel) == "unchanged"
    refute File.exists?(Path.join(outside, "missing"))
  end

  test "rejects a final Log symlink and a pre-existing temporary symlink", %{
    workspace: ws,
    outside: outside
  } do
    assert {:ok, _} = Paths.ensure_state_dir(ws, Paths.sessions_dir(ws))
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "unchanged")
    log = Paths.session_log("safe", ws)
    File.ln_s!(sentinel, log)

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             Paths.inspect_state_path(ws, log, expected: :regular)

    File.rm!(log)
    temp = log <> ".tmp-known"
    File.ln_s!(sentinel, temp)

    assert {:error, %{error: %{kind: :unsafe_state_path, details: %{"component" => component}}}} =
             Paths.preflight_new_state_path(ws, temp)

    assert String.ends_with?(component, ".tmp-known")
    assert File.read!(sentinel) == "unchanged"
  end

  test "rejects a symlink loop and a regular file used as a directory", %{workspace: ws} do
    File.ln_s!(".pixir", Paths.project_root(ws))

    assert {:error, %{error: %{kind: :unsafe_state_path}}} =
             Paths.inspect_state_path(ws, Paths.session_log("safe", ws), expected: :regular)

    File.rm!(Paths.project_root(ws))
    File.write!(Paths.project_root(ws), "not-a-directory")

    assert {:error, %{error: %{kind: :unsafe_state_path, details: %{"reason" => reason}}}} =
             Paths.ensure_state_dir(ws, Paths.sessions_dir(ws))

    assert reason == "non_directory_component"
  end
end
