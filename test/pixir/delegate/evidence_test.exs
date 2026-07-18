defmodule Pixir.Delegate.EvidenceTest do
  use ExUnit.Case, async: false

  alias Pixir.Delegate.Evidence
  alias Pixir.{Event, Log, Paths}

  test "parent mirror refuses ancestor and final Log symlinks without copying target bytes" do
    for symlink_kind <- [:sessions_ancestor, :final_log] do
      with_fixture("parent-#{symlink_kind}", fn root, workspace, outside, home ->
        session_id = "parent-safe"
        outside_log = Path.join(outside, "outside-parent.ndjson")
        File.write!(outside_log, "OUTSIDE_PARENT_SENTINEL_BYTES")

        case symlink_kind do
          :sessions_ancestor ->
            File.mkdir_p!(Paths.project_root(workspace))

            File.write!(
              Path.join(outside, session_id <> ".ndjson"),
              "OUTSIDE_PARENT_SENTINEL_BYTES"
            )

            File.ln_s!(outside, Paths.sessions_dir(workspace))

          :final_log ->
            Paths.ensure_sessions_dir(workspace)
            File.ln_s!(outside_log, Paths.session_log(session_id, workspace))
        end

        assert {:ok, result} = Evidence.refresh_payload(payload(session_id, workspace))
        assert result["evidence"]["mirror"]["status"] == "mirror_failed"

        assert result["evidence"]["mirror"]["parent_log"]["error"]["kind"] ==
                 "unsafe_state_path"

        refute mirror_contains?(home, "OUTSIDE_PARENT_SENTINEL_BYTES")
        assert File.read!(outside_log) == "OUTSIDE_PARENT_SENTINEL_BYTES"
        assert File.dir?(root)
      end)
    end
  end

  test "child mirror rejects an arbitrary child_log_path before copying" do
    with_fixture("arbitrary-child", fn _root, workspace, outside, home ->
      parent_id = "parent-safe"
      event = Event.user_message(parent_id, "parent") |> Event.with_seq(0)
      assert {:ok, [_]} = Log.create_session(parent_id, [event], workspace: workspace)

      outside_child = Path.join(outside, "child.ndjson")
      File.write!(outside_child, "CHILD_OUTSIDE_SENTINEL")

      hostile_payload =
        payload(parent_id, workspace)
        |> Map.put("children", [
          %{"child_session_id" => "child-safe", "child_log_path" => outside_child}
        ])

      assert {:error, %{error: %{kind: :invalid_args}} = error} =
               Evidence.refresh_payload(hostile_payload)

      refute inspect(error) =~ outside_child
      refute mirror_contains?(home, "CHILD_OUTSIDE_SENTINEL")
      assert File.read!(outside_child) == "CHILD_OUTSIDE_SENTINEL"
    end)
  end

  test "child mirror preflights a canonical child Log in its inferred workspace" do
    with_fixture("canonical-child-symlink", fn root, workspace, outside, home ->
      parent_id = "parent-safe"
      child_id = "child-safe"
      child_workspace = Path.join(root, "child-workspace")
      File.mkdir_p!(child_workspace)
      event = Event.user_message(parent_id, "parent") |> Event.with_seq(0)
      assert {:ok, [_]} = Log.create_session(parent_id, [event], workspace: workspace)

      File.mkdir_p!(Paths.project_root(child_workspace))
      outside_child = Path.join(outside, child_id <> ".ndjson")
      File.write!(outside_child, "CHILD_CANONICAL_SYMLINK_SENTINEL")
      File.ln_s!(outside, Paths.sessions_dir(child_workspace))

      result_payload =
        payload(parent_id, workspace)
        |> Map.put("children", [
          %{
            "child_session_id" => child_id,
            "child_log_path" => Log.path(child_id, workspace: child_workspace)
          }
        ])

      assert {:ok, result} = Evidence.refresh_payload(result_payload)
      assert result["evidence"]["mirror"]["status"] == "mirror_failed"

      assert [%{"status" => "mirror_failed", "error" => %{"kind" => "unsafe_state_path"}}] =
               result["evidence"]["mirror"]["child_logs"]

      refute mirror_contains?(home, "CHILD_CANONICAL_SYMLINK_SENTINEL")
      assert File.read!(outside_child) == "CHILD_CANONICAL_SYMLINK_SENTINEL"
    end)
  end

  defp payload(session_id, workspace) do
    %{
      "status" => "running",
      "kind" => "delegate_result",
      "delegate_id" => "dlg_safe",
      "session_id" => session_id,
      "workspace" => workspace,
      "mode" => "bounded_write"
    }
  end

  defp with_fixture(name, fun) do
    root =
      Path.join(
        System.tmp_dir!(),
        "pixir-evidence-#{name}-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      )

    workspace = Path.join(root, "workspace")
    outside = Path.join(root, "outside")
    home = Path.join(root, "home")
    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    previous_home = System.get_env("PIXIR_HOME")
    System.put_env("PIXIR_HOME", home)

    try do
      fun.(root, workspace, outside, home)
    after
      if previous_home,
        do: System.put_env("PIXIR_HOME", previous_home),
        else: System.delete_env("PIXIR_HOME")

      File.rm_rf!(root)
    end
  end

  defp mirror_contains?(home, sentinel) do
    home
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, bytes} -> String.contains?(bytes, sentinel)
        {:error, _reason} -> false
      end
    end)
  end
end
