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
